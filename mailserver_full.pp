# Mail Server — Full Corporate Edition
# Includes: Postfix, Dovecot, MySQL virtual users, Roundcube, PostfixAdmin,
#           OpenDKIM, SpamAssassin, Fail2ban, Sieve, Quotas, Vacation,
#           Mailman, Autodiscover, Backup, Nginx+PHP
# Run: sudo puppet apply mailserver_full.pp

$domain     = 'example.com'
$hostname   = "mail.${domain}"
$ssl_cert   = '/etc/ssl/certs/mail.pem'
$ssl_key    = '/etc/ssl/private/mail.key'
$db_pass    = 'maildbpass123'
$admin_pass = 'adminpass123'

# =====================================================
# PACKAGES
# =====================================================
$base_pkgs = [
  'postfix', 'postfix-mysql',
  'dovecot-core', 'dovecot-imapd', 'dovecot-pop3d',
  'dovecot-sieve', 'dovecot-managesieved', 'dovecot-mysql',
  'dovecot-lmtpd',
  'opendkim', 'opendkim-tools',
  'spamassassin', 'spamc', 'razor', 'pyzor',
  'fail2ban', 'mailutils', 'ufw',
]
package { $base_pkgs: ensure => installed }

$web_pkgs = [
  'mariadb-server', 'mariadb-client',
  'nginx', 'php8.3-fpm', 'php8.3-mysql', 'php8.3-mbstring',
  'php8.3-imap', 'php8.3-xml', 'php8.3-curl', 'php8.3-zip',
  'php8.3-gd', 'php8.3-intl',
  'roundcube',
  'postfixadmin',
  'certbot', 'python3-certbot-nginx',
]
package { $web_pkgs: ensure => installed }

# =====================================================
# SSL SELF-SIGNED CERT (replace with Let's Encrypt for production)
# =====================================================
exec { 'gen-mail-cert':
  command => "openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout ${ssl_key} -out ${ssl_cert} -subj '/CN=${hostname}'",
  creates => $ssl_cert,
  path    => ['/usr/bin', '/usr/sbin'],
}
file { $ssl_key:
  mode  => '0600',
  owner => 'root',
  group => 'root',
}

# =====================================================
# MARIADB + MAIL DATABASE
# =====================================================
service { 'mariadb':
  ensure => running,
  enable => true,
}

exec { 'wait-mariadb':
  command => 'until mysqladmin ping -h localhost --silent; do sleep 1; done',
  unless  => 'mysqladmin ping -h localhost --silent',
  path    => ['/usr/bin'],
  require => Service['mariadb'],
}

exec { 'create-mail-db':
  command => "mysql -e \"CREATE DATABASE IF NOT EXISTS mailserver;
CREATE USER IF NOT EXISTS 'mailuser'@'localhost' IDENTIFIED BY '${db_pass}';
GRANT ALL ON mailserver.* TO 'mailuser'@'localhost';
FLUSH PRIVILEGES;
\"",
  unless  => "mysql -umailuser -p${db_pass} -e 'USE mailserver' 2>/dev/null",
  path    => ['/usr/bin'],
  require => Exec['wait-mariadb'],
}

# Seed PostfixAdmin tables: domain, admin, mailbox, aliases
# The password scheme must match $CONF['encrypt'] in PostfixAdmin config (md5crypt by default)
# maildir format: domain/user/ (matches domain_path=YES, domain_in_mailbox=NO)
exec { 'seed-mail-db':
  command => "mysql mailserver -e \"
INSERT IGNORE INTO domain (domain, description, aliases, mailboxes, quota, transport, backupmx, created, modified, active)
  VALUES ('${domain}', 'Default domain', 0, 0, 0, 'virtual', 0, NOW(), NOW(), 1);
INSERT IGNORE INTO admin (username, password, superadmin, created, modified, active)
  VALUES ('admin@${domain}', ENCRYPT('${admin_pass}', CONCAT('\\\$1\\\$', SUBSTRING(MD5(RAND()), -8))), 1, NOW(), NOW(), 1);
INSERT IGNORE INTO domain_admins (username, domain, created, active)
  VALUES ('admin@${domain}', 'ALL', NOW(), 1);
INSERT IGNORE INTO mailbox (username, password, name, maildir, quota, local_part, domain, created, modified, active)
  VALUES ('admin@${domain}', ENCRYPT('${admin_pass}', CONCAT('\\\$1\\\$', SUBSTRING(MD5(RAND()), -8))), 'Admin', '${domain}/admin/', 1073741824, 'admin', '${domain}', NOW(), NOW(), 1);
INSERT IGNORE INTO mailbox (username, password, name, maildir, quota, local_part, domain, created, modified, active)
  VALUES ('postmaster@${domain}', ENCRYPT('${admin_pass}', CONCAT('\\\$1\\\$', SUBSTRING(MD5(RAND()), -8))), 'Postmaster', '${domain}/postmaster/', 1073741824, 'postmaster', '${domain}', NOW(), NOW(), 1);
INSERT IGNORE INTO alias (address, goto, domain, created, modified, active)
  VALUES ('abuse@${domain}', 'admin@${domain}', '${domain}', NOW(), NOW(), 1);
INSERT IGNORE INTO alias (address, goto, domain, created, modified, active)
  VALUES ('hostmaster@${domain}', 'admin@${domain}', '${domain}', NOW(), NOW(), 1);
INSERT IGNORE INTO alias (address, goto, domain, created, modified, active)
  VALUES ('postmaster@${domain}', 'admin@${domain}', '${domain}', NOW(), NOW(), 1);
INSERT IGNORE INTO alias (address, goto, domain, created, modified, active)
  VALUES ('webmaster@${domain}', 'admin@${domain}', '${domain}', NOW(), NOW(), 1);
INSERT IGNORE INTO alias (address, goto, domain, created, modified, active)
  VALUES ('info@${domain}', 'admin@${domain}', '${domain}', NOW(), NOW(), 1);
INSERT IGNORE INTO alias (address, goto, domain, created, modified, active)
  VALUES ('support@${domain}', 'admin@${domain}', '${domain}', NOW(), NOW(), 1);
\"",
  unless  => "mysql -umailuser -p${db_pass} -e \"SELECT 1 FROM mailserver.domain WHERE domain='${domain}'\" 2>/dev/null | grep -q 1",
  path    => ['/usr/bin'],
  require => Exec['postfixadmin-schema'],
}

# Create mailbox directories on disk
exec { 'create-maildir-dirs':
  command => "mkdir -p /var/mail/vmail/${domain}/admin /var/mail/vmail/${domain}/postmaster && chown -R vmail:vmail /var/mail/vmail/${domain}",
  creates => "/var/mail/vmail/${domain}/admin",
  path    => ['/bin', '/usr/bin'],
  require => [User['vmail'], Exec['seed-mail-db']],
}

# MySQL config files for Postfix/Dovecot
file { '/etc/postfix/mysql-virtual-domains.cf':
  ensure  => file,
  content => "user = mailuser\npassword = ${db_pass}\nhosts = 127.0.0.1\ndbname = mailserver\nquery = SELECT 1 FROM domain WHERE domain='%s' AND active=1\n",
  mode    => '0640',
  group   => 'postfix',
}

file { '/etc/postfix/mysql-virtual-mailbox.cf':
  ensure  => file,
  content => "user = mailuser\npassword = ${db_pass}\nhosts = 127.0.0.1\ndbname = mailserver\nquery = SELECT maildir FROM mailbox WHERE username='%s' AND active=1\n",
  mode    => '0640',
  group   => 'postfix',
}

file { '/etc/postfix/mysql-virtual-aliases.cf':
  ensure  => file,
  content => "user = mailuser\npassword = ${db_pass}\nhosts = 127.0.0.1\ndbname = mailserver\nquery = SELECT goto FROM alias WHERE address='%s' AND active=1\n",
  mode    => '0640',
  group   => 'postfix',
}

file { '/etc/postfix/mysql-virtual-email2email.cf':
  ensure  => file,
  content => "user = mailuser\npassword = ${db_pass}\nhosts = 127.0.0.1\ndbname = mailserver\nquery = SELECT username FROM mailbox WHERE username='%s' AND active=1\n",
  mode    => '0640',
  group   => 'postfix',
}

# =====================================================
# VMAIL USER + MAIL STORAGE
# =====================================================
group { 'vmail':
  ensure => present,
  gid    => 5000,
}
user { 'vmail':
  ensure     => present,
  gid        => 5000,
  uid        => 5000,
  home       => '/var/mail/vmail',
  managehome => true,
  shell      => '/usr/sbin/nologin',
  require    => Group['vmail'],
}
file { '/var/mail/vmail':
  ensure => directory,
  owner  => 'vmail',
  group  => 'vmail',
  mode   => '0770',
  require => User['vmail'],
}

# =====================================================
# OPENDKIM
# =====================================================
file { '/etc/opendkim.conf':
  ensure  => file,
  content => "AutoRestart Yes\nAutoRestartRate 10/1h\nSyslog yes\nSyslogSuccess yes\nLogWhy yes\nCanonicalization relaxed/simple\nMode sv\nSubDomains no\nOversignHeaders From\nSignatureAlgorithm rsa-sha256\nUserID opendkim\nSocket inet:8891@localhost\nPidFile /run/opendkim/opendkim.pid\nUMask 007\nExternalIgnoreList refile:/etc/opendkim/TrustedHosts\nInternalHosts refile:/etc/opendkim/TrustedHosts\nKeyTable refile:/etc/opendkim/KeyTable\nSigningTable refile:/etc/opendkim/SigningTable\n",
  notify  => Service['opendkim'],
}

file { '/etc/opendkim':
  ensure => directory,
  owner  => 'opendkim',
  group  => 'opendkim',
  mode   => '0750',
}

file { '/etc/opendkim/keys':
  ensure => directory,
  owner  => 'opendkim',
  group  => 'opendkim',
  mode   => '0750',
}

file { '/etc/opendkim/TrustedHosts':
  ensure  => file,
  content => "127.0.0.1\nlocalhost\n${hostname}\n${domain}\n",
}

file { '/etc/opendkim/KeyTable':
  ensure  => file,
  content => "mail._domainkey.${domain} ${domain}:${hostname}:/etc/opendkim/keys/mail.private\n",
}

file { '/etc/opendkim/SigningTable':
  ensure  => file,
  content => "*@${domain} mail._domainkey.${domain}\n",
}

exec { 'gen-dkim-key':
  command => "opendkim-genkey -b 2048 -d ${domain} -D /etc/opendkim/keys/ -s mail -v",
  creates => '/etc/opendkim/keys/mail.private',
  path    => ['/usr/bin', '/usr/sbin'],
  require => File['/etc/opendkim/keys'],
}

exec { 'fix-dkim-perms':
  command => 'chown -R opendkim:opendkim /etc/opendkim/keys/',
  unless  => 'test "$(stat -c %U /etc/opendkim/keys/mail.private)" = "opendkim"',
  path    => ['/bin', '/usr/bin'],
  require => Exec['gen-dkim-key'],
}

service { 'opendkim':
  ensure     => running,
  enable     => true,
  hasrestart => true,
  require    => Exec['gen-dkim-key'],
}

# =====================================================
# POSTFIX — Virtual Users + MySQL
# =====================================================
$postfix_main = "myhostname = ${hostname}
mydomain = ${domain}
myorigin = ${domain}
inet_interfaces = all
mydestination = localhost
mynetworks = 127.0.0.0/8 [::1]/128
mailbox_size_limit = 0
message_size_limit = 52428800
compatibility_level = 3.6
recipient_delimiter = +

# Virtual mail
virtual_mailbox_base = /var/mail/vmail
virtual_uid_maps = static:5000
virtual_gid_maps = static:5000
virtual_transport = lmtp:unix:private/dovecot-lmtp

virtual_mailbox_domains = mysql:/etc/postfix/mysql-virtual-domains.cf
virtual_mailbox_maps = mysql:/etc/postfix/mysql-virtual-mailbox.cf
virtual_alias_maps = mysql:/etc/postfix/mysql-virtual-aliases.cf, mysql:/etc/postfix/mysql-virtual-email2email.cf

# TLS
smtpd_tls_cert_file = ${ssl_cert}
smtpd_tls_key_file = ${ssl_key}
smtpd_use_tls = yes
smtpd_tls_auth_only = yes
smtpd_tls_security_level = may
smtp_tls_security_level = may

# SASL
smtpd_sasl_type = dovecot
smtpd_sasl_path = private/auth
smtpd_sasl_auth_enable = yes

# Restrictions
smtpd_helo_required = yes
smtpd_client_restrictions = permit_sasl_authenticated, permit_mynetworks
smtpd_sender_restrictions = permit_sasl_authenticated, permit_mynetworks, reject_non_fqdn_sender, reject_unknown_sender_domain
smtpd_recipient_restrictions = permit_sasl_authenticated, permit_mynetworks, reject_unauth_destination, reject_non_fqdn_recipient
smtpd_relay_restrictions = permit_sasl_authenticated, permit_mynetworks, reject_unauth_destination

# OpenDKIM
milter_default_action = accept
milter_protocol = 6
smtpd_milters = inet:localhost:8891
non_smtpd_milters = inet:localhost:8891
"

file { '/etc/postfix/main.cf':
  ensure  => file,
  content => $postfix_main,
  notify  => Service['postfix'],
}

# SpamAssassin transport + SMTP filter in master.cf
exec { 'master-cf-spamassassin':
  command => 'grep -q "^spamassassin" /etc/postfix/master.cf || (printf "spamassassin unix -     n       n       -       -       pipe\n  user=debian-spamd argv=/usr/bin/spamc -f -e /usr/sbin/sendmail -oi -f \${sender} \${recipient}\n" >> /etc/postfix/master.cf)',
  unless  => 'grep -q "^spamassassin" /etc/postfix/master.cf',
  path    => ['/bin', '/usr/bin'],
  require => Package['postfix'],
  notify  => Service['postfix'],
}

# Add content_filter to smtp listener (avoids loop — pickup has no filter)
exec { 'master-cf-smtp-filter':
  command => 'grep -A1 "^smtp.*inet" /etc/postfix/master.cf | grep -q "content_filter" || sed -i "/^smtp\\s.*inet/a\\  -o content_filter=spamassassin" /etc/postfix/master.cf',
  unless  => 'grep -A1 "^smtp.*inet" /etc/postfix/master.cf | grep -q "content_filter"',
  path    => ['/bin', '/usr/bin'],
  require => Package['postfix'],
  notify  => Service['postfix'],
}

# Submission port in master.cf
exec { 'master-cf-submission':
  command => "sed -i 's/^#submission/submission/' /etc/postfix/master.cf || true",
  unless  => 'grep -q "^submission " /etc/postfix/master.cf',
  path    => ['/bin', '/usr/bin'],
  require => Package['postfix'],
  notify  => Service['postfix'],
}

service { 'postfix':
  ensure     => running,
  enable     => true,
  hasrestart => true,
}

# =====================================================
# DOVECOT — Virtual Users + MySQL + Quota + Sieve
# =====================================================
file { '/etc/dovecot/dovecot-sql.conf.ext':
  ensure  => file,
  content => "driver = mysql\nconnect = host=127.0.0.1 dbname=mailserver user=mailuser password=${db_pass}\ndefault_pass_scheme = MD5-CRYPT\npassword_query = SELECT username AS user, password FROM mailbox WHERE username='%u' AND active=1\nuser_query = SELECT CONCAT('/var/mail/vmail/', domain, '/', local_part) AS home, 5000 AS uid, 5000 AS gid, CONCAT('*:bytes=', quota) AS quota_rule FROM mailbox WHERE username='%u' AND active=1\niterate_query = SELECT username AS user FROM mailbox WHERE active=1\n",
  mode    => '0640',
  owner   => 'root',
  group   => 'dovecot',
}

file { '/etc/dovecot/dovecot.conf':
  ensure  => file,
  content => "protocols = imap pop3 lmtp sieve\nmail_location = maildir:/var/mail/vmail/%d/%n/Maildir\nssl = yes\nssl_cert = </etc/ssl/certs/mail.pem\nssl_key = </etc/ssl/private/mail.key\ndisable_plaintext_auth = no\nauth_mechanisms = plain login\nfirst_valid_uid = 5000\nlast_valid_uid = 5000\nfirst_valid_gid = 5000\nlast_valid_gid = 5000\n!include conf.d/*.conf\n",
  notify  => Service['dovecot'],
}

file { '/etc/dovecot/conf.d/10-auth.conf':
  ensure  => file,
  content => "disable_plaintext_auth = no\nauth_mechanisms = plain login\n!include auth-sql.conf.ext\n",
  notify  => Service['dovecot'],
}

file { '/etc/dovecot/conf.d/10-mail.conf':
  ensure  => file,
  content => "mail_location = maildir:/var/mail/vmail/%d/%n/Maildir\nnamespace inbox {\n  separator = /\n  inbox = yes\n}\nmail_uid = 5000\nmail_gid = 5000\n",
  notify  => Service['dovecot'],
}

file { '/etc/dovecot/conf.d/10-master.conf':
  ensure  => file,
  content => "service auth {
  unix_listener /var/spool/postfix/private/auth {
    mode = 0660
    user = postfix
    group = postfix
  }
}
service lmtp {
  unix_listener /var/spool/postfix/private/dovecot-lmtp {
    mode = 0600
    user = postfix
    group = postfix
  }
}
service imap-login {
  inet_listener imap {
    port = 143
  }
  inet_listener imaps {
    port = 993
    ssl = yes
  }
}
service pop3-login {
  inet_listener pop3 {
    port = 110
  }
  inet_listener pop3s {
    port = 995
    ssl = yes
  }
}
service managesieve-login {
  inet_listener sieve {
    port = 4190
  }
}
service managesieve {
}
",
  notify  => Service['dovecot'],
}

file { '/etc/dovecot/conf.d/15-lda.conf':
  ensure  => file,
  content => "lda_mailbox_autocreate = yes\nlda_mailbox_autosubscribe = yes\nprotocol lda {\n  mail_plugins = \$mail_plugins sieve quota\n}\n",
  notify  => Service['dovecot'],
}

file { '/etc/dovecot/conf.d/15-mailboxes.conf':
  ensure  => file,
  content => "namespace inbox {\n  mailbox Junk {\n    auto = create\n    special_use = \\Junk\n  }\n  mailbox Trash {\n    auto = create\n    special_use = \\Trash\n  }\n  mailbox Sent {\n    auto = create\n    special_use = \\Sent\n  }\n  mailbox Drafts {\n    auto = create\n    special_use = \\Drafts\n  }\n}\n",
  notify  => Service['dovecot'],
}

# Quota
file { '/etc/dovecot/conf.d/90-quota.conf':
  ensure  => file,
  content => "plugin {\n  quota = maildir:User quota\n  quota_rule = *:storage=1G\n  quota_rule2 = Trash:storage=+100M\n  quota_grace = 10%%\n}\nservice quota-status {\n  executable = quota-status -p postfix\n  unix_listener /var/spool/postfix/private/quota-status {\n    mode = 0660\n    user = postfix\n    group = postfix\n  }\n  client_limit = 1\n}\n",
  notify  => Service['dovecot'],
}

# LMTP with Sieve
file { '/etc/dovecot/conf.d/20-lmtp.conf':
  ensure  => file,
  content => "protocol lmtp {\n  mail_plugins = \$mail_plugins sieve quota\n  postmaster_address = postmaster@${domain}\n}\n",
  notify  => Service['dovecot'],
}

# Sieve — spam to Junk + vacation
file { '/etc/dovecot/sieve':
  ensure => directory,
  owner  => 'vmail',
  group  => 'vmail',
}

file { '/etc/dovecot/sieve/default.sieve':
  ensure  => file,
  content => 'require ["fileinto", "vacation", "envelope"];
if header :contains "X-Spam-Flag" "YES" {
  fileinto "Junk";
  stop;
}
',
  owner   => 'vmail',
  group   => 'vmail',
  require => File['/etc/dovecot/sieve'],
}

exec { 'compile-sieve':
  command => 'sievec /etc/dovecot/sieve/default.sieve && chown vmail:vmail /etc/dovecot/sieve/default.svbin',
  creates => '/etc/dovecot/sieve/default.svbin',
  path    => ['/usr/bin'],
  require => [File['/etc/dovecot/sieve/default.sieve'], User['vmail']],
}

file { '/etc/dovecot/conf.d/90-sieve.conf':
  ensure  => file,
  content => "plugin {\n  sieve = file:/var/mail/vmail/%d/%n/sieve;active=/var/mail/vmail/%d/%n/.dovecot.sieve\n  sieve_before = /etc/dovecot/sieve/default.sieve\n  sieve_extensions = +vacation +notify\n}\n",
  notify  => Service['dovecot'],
}

service { 'dovecot':
  ensure     => running,
  enable     => true,
  hasrestart => true,
}

# =====================================================
# SPAMASSASSIN
# =====================================================
$sa_local_cf = "rewrite_header Subject ***** SPAM *****
report_safe 1
required_score 5.0
add_header all Status _YESNO_, score=_SCORE_ required=_REQD_ tests=_TESTS_ autolearn=_AUTOLEARN_
add_header spam Flag _YESNO_
add_header all Level _STARS_
use_bayes 1
bayes_auto_learn 1
bayes_auto_learn_threshold_nonspam -0.5
bayes_auto_learn_threshold_spam 8.0
skip_rbl_checks 0
dnsbl_timeout 10
use_razor2 1
razor_config /etc/spamassassin/razor/razor-agent.conf
use_pyzor 1
pyzor_options --homedir /etc/spamassassin/pyzor
score RCVD_IN_BL_SPAMCOP_NET 2.0
score RCVD_IN_SBL 3.0
score RCVD_IN_XBL 3.0
score RCVD_IN_PBL 2.5
score URIBL_BLACK 3.0
score SPF_FAIL 3.0
score SPF_SOFTFAIL 1.5
score DKIM_INVALID 0.1
body VIAGRA_GENERIC /viagra|cialis|pharmacy|meds/i
describe VIAGRA_GENERIC Common spam keywords
score VIAGRA_GENERIC 4.0
uri URI_SUSPICIOUS /\\.(xyz|top|click|loan|work|pw|tk|ml|ga|cf)\\//i
describe URI_SUSPICIOUS Suspicious TLD in URL
score URI_SUSPICIOUS 2.5
"

file { '/etc/spamassassin/local.cf':
  ensure  => file,
  content => $sa_local_cf,
  notify  => Service['spamd'],
}

exec { 'razor-setup':
  command => 'razor-admin -home=/etc/spamassassin/razor -create && razor-admin -home=/etc/spamassassin/razor -register',
  creates => '/etc/spamassassin/razor/razor-agent.conf',
  path    => ['/usr/bin', '/bin'],
}

exec { 'pyzor-setup':
  command => 'mkdir -p /etc/spamassassin/pyzor && pyzor --homedir /etc/spamassassin/pyzor discover',
  creates => '/etc/spamassassin/pyzor/servers',
  path    => ['/usr/bin', '/bin'],
}

exec { 'sa-update-rules':
  command => 'sa-update && sa-compile',
  creates => '/var/lib/spamassassin/compiled',
  path    => ['/usr/bin', '/usr/sbin', '/bin'],
}

file { '/etc/default/spamassassin':
  ensure  => file,
  content => "ENABLED=1\nSAHOME=\"/var/lib/spamassassin\"\nOPTIONS=\"--create-prefs --max-children 5 --helper-home-dir=\${SAHOME}\"\nPIDFILE=\"\${SAHOME}/spamd.pid\"\nCRON=1\n",
  notify  => Service['spamd'],
}

service { 'spamd':
  ensure     => running,
  enable     => true,
  hasrestart => true,
}

# =====================================================
# FAIL2BAN
# =====================================================
file { '/etc/fail2ban/jail.local':
  ensure  => file,
  content => "[DEFAULT]\nbantime   = 1h\nfindtime  = 10m\nmaxretry  = 5\nbackend   = systemd\nallowipv6 = auto\n\n[sshd]\nenabled  = true\nport     = ssh\nfilter   = sshd\nlogpath  = /var/log/auth.log\n\n[postfix]\nenabled  = true\nport     = smtp,submission\nfilter   = postfix\nlogpath  = /var/log/mail.log\nmaxretry = 3\n\n[dovecot]\nenabled  = true\nport     = pop3,pop3s,imap,imaps,submission\nfilter   = dovecot\nlogpath  = /var/log/mail.log\nmaxretry = 3\n\n[sieve]\nenabled  = true\nport     = 4190\nfilter   = dovecot\nlogpath  = /var/log/mail.log\nmaxretry = 3\n",
  notify  => Service['fail2ban'],
}

service { 'fail2ban':
  ensure     => running,
  enable     => true,
  hasrestart => true,
}

# =====================================================
# NGINX + PHP-FPM
# =====================================================
service { 'php8.3-fpm':
  ensure => running,
  enable => true,
}

file { '/etc/nginx/sites-available/mail.conf':
  ensure  => file,
  content => "server {\n  listen 80;\n  listen [::]:80;\n  server_name ${hostname} ${domain} autodiscover.${domain} autoconfig.${domain};\n  root /var/www/html;\n\n  # Let's Encrypt\n  location /.well-known/acme-challenge/ {\n    root /var/www/html;\n  }\n\n  # Roundcube webmail\n  location /mail {\n    alias /var/lib/roundcube;\n    index index.php;\n    location ~ ^/mail/(.+\\.php)(.*)$ {\n      include fastcgi_params;\n      fastcgi_pass unix:/run/php/php8.3-fpm.sock;\n      fastcgi_param SCRIPT_FILENAME \$request_filename;\n    }\n    location ~ ^/mail/(.*)$ {\n      alias /var/lib/roundcube/\$1;\n    }\n  }\n\n  # PostfixAdmin\n  location /admin {\n    alias /usr/share/postfixadmin/public/;\n    index index.php;\n    try_files \$uri \$uri/ /index.php?\$args;\n  }\n  location ~ ^/admin/(.+\\.php)$ {\n    alias /usr/share/postfixadmin/public/;\n    fastcgi_pass unix:/run/php/php8.3-fpm.sock;\n    fastcgi_param SCRIPT_FILENAME /usr/share/postfixadmin/public/\$1;\n    include fastcgi_params;\n  }\n\n  # Autodiscover (Outlook)\n  location /autodiscover/autodiscover.xml {\n    fastcgi_pass unix:/run/php/php8.3-fpm.sock;\n    include fastcgi_params;\n    fastcgi_param SCRIPT_FILENAME /var/www/html/autodiscover.php;\n    fastcgi_param HTTPS on;\n  }\n\n  # Autoconfig (Thunderbird)\n  location /.well-known/autoconfig/mail/config-v1.1.xml {\n    default_type application/xml;\n    return 200 '<?xml version=\"1.0\"?><clientConfig version=\"1.1\"><emailProvider id=\"${domain}\"><domain>${domain}</domain><displayName>Mail</displayName><incomingServer type=\"imap\"><hostname>${hostname}</hostname><port>993</port><socketType>SSL</socketType><username>%EMAILADDRESS%</username><authentication>password-cleartext</authentication></incomingServer><incomingServer type=\"pop3\"><hostname>${hostname}</hostname><port>995</port><socketType>SSL</socketType><username>%EMAILADDRESS%</username><authentication>password-cleartext</authentication></incomingServer><outgoingServer type=\"smtp\"><hostname>${hostname}</hostname><port>587</port><socketType>STARTTLS</socketType><username>%EMAILADDRESS%</username><authentication>password-cleartext</authentication></outgoingServer></emailProvider></clientConfig>';\n  }\n}\n",
  notify  => Service['nginx'],
}

file { '/etc/nginx/sites-enabled/mail.conf':
  ensure  => link,
  target  => '/etc/nginx/sites-available/mail.conf',
  notify  => Service['nginx'],
}

# Remove default nginx site
file { '/etc/nginx/sites-enabled/default':
  ensure => absent,
  notify => Service['nginx'],
}

# Autodiscover PHP script for Outlook
file { '/var/www/html/autodiscover.php':
  ensure  => file,
  content => "<?php\n\$email = \$_SERVER['HTTP_HOST'] ?? '';\n\$domain = '${domain}';\n\$host = '${hostname}';\nheader('Content-Type: application/xml');\necho '<?xml version=\"1.0\" encoding=\"utf-8\"?>';\necho '<Autodiscover xmlns=\"http://schemas.microsoft.com/exchange/autodiscover/responseschema/2006\">';\necho '<Response xmlns=\"http://schemas.microsoft.com/exchange/autodiscover/outlook/responseschema/2006a\">';\necho '<Account><AccountType>email</AccountType><Action>settings</Action>';echo '<Protocol><Type>IMAP</Type><Server>'.\$host.'</Server><Port>993</Port><SSL>on</SSL><AuthRequired>on</AuthRequired></Protocol>';echo '<Protocol><Type>SMTP</Type><Server>'.\$host.'</Server><Port>587</Port><Encryption>TLS</Encryption><AuthRequired>on</AuthRequired></Protocol>';echo '</Account></Response></Autodiscover>';\n?>",
}

service { 'nginx':
  ensure     => running,
  enable     => true,
  hasrestart => true,
}

# =====================================================
# ROUNDCUBE CONFIG
# =====================================================
file { '/etc/roundcube/config.inc.php':
  ensure  => file,
  content => "<?php\n\$config['db_dsnw'] = 'mysql://roundcube:roundcube@localhost/roundcube';\n\$config['imap_host'] = 'localhost:143';\n\$config['smtp_host'] = 'localhost:587';\n\$config['smtp_user'] = '%u';\n\$config['smtp_pass'] = '%p';\n\$config['support_url'] = 'mailto:postmaster@${domain}';\n\$config['product_name'] = 'Corporate Mail';\n\$config['des_key'] = 'rcmail-${domain}-2024corp';\n\$config['plugins'] = ['archive','zipdownload','managesieve','markasjunk','newmail_notifier','vacation'];\n\$config['language'] = 'en_US';\n\$config['enable_installer'] = false;\n?>",
  require => Package['roundcube'],
}

# Roundcube database
exec { 'roundcube-db':
  command => "mysql -e \"CREATE DATABASE IF NOT EXISTS roundcube; CREATE USER IF NOT EXISTS 'roundcube'@'localhost' IDENTIFIED BY 'roundcube'; GRANT ALL ON roundcube.* TO 'roundcube'@'localhost'; FLUSH PRIVILEGES;\"",
  unless  => "mysql -uroundcube -proundcube -e 'USE roundcube' 2>/dev/null",
  path    => ['/usr/bin'],
  require => Service['mariadb'],
}

exec { 'roundcube-schema':
  command => "mysql roundcube < /usr/share/roundcube/SQL/mysql.initial.sql && touch /var/lib/roundcube/.schema-loaded",
  creates => '/var/lib/roundcube/.schema-loaded',
  path    => ['/usr/bin'],
  require => [Exec['roundcube-db'], Package['roundcube']],
}

file { '/var/lib/roundcube/temp':
  ensure => directory,
  owner  => 'www-data',
  group  => 'www-data',
  mode   => '0770',
  require => Exec['roundcube-schema'],
}

# =====================================================
# POSTFIXADMIN CONFIG
# =====================================================
file { '/etc/postfixadmin/config.local.php':
  ensure  => file,
  content => "<?php\n\$CONF['configured'] = true;\n\$CONF['encrypt'] = 'md5crypt';\n\$CONF['database_type'] = 'mysqli';\n\$CONF['database_host'] = 'localhost';\n\$CONF['database_user'] = 'mailuser';\n\$CONF['database_password'] = '${db_pass}';\n\$CONF['database_name'] = 'mailserver';\n\$CONF['admin_email'] = 'postmaster@${domain}';\n\$CONF['default_aliases'] = array('abuse' => 'admin@${domain}', 'hostmaster' => 'admin@${domain}', 'postmaster' => 'admin@${domain}', 'webmaster' => 'admin@${domain}');\n\$CONF['domain_path'] = 'YES';\n\$CONF['domain_in_mailbox'] = 'NO';\n\$CONF['mailbox_postcreation_script'] = 'sudo /usr/local/bin/postfixadmin-mailbox-postcreate.sh';\n\$CONF['fetchmail'] = 'NO';\n\$CONF['show_footer_text'] = 'NO';\n\$CONF['quota'] = 'YES';\n\$CONF['used_quotas'] = 'YES';\n\$CONF['new_quota_table'] = 'YES';\n\$CONF['vacation'] = 'YES';\n\$CONF['vacation_domain'] = 'autoreply.${domain}';\n\$CONF['password_expiration'] = 'NO';\n?>",
  require => Package['postfixadmin'],
}

# Copy PostfixAdmin schema file
# Place postfixadmin_schema.sql alongside this .pp file before running
exec { 'postfixadmin-schema':
  command => "mysql mailserver < /root/PuppetCode/postfixadmin_schema.sql",
  unless  => "mysql -umailuser -p${db_pass} -e 'SHOW TABLES LIKE \"domain\"' mailserver 2>/dev/null | grep -q domain",
  path    => ['/usr/bin'],
  require => [Exec['create-mail-db'], File['/etc/postfixadmin/config.local.php']],
}

# PostfixAdmin config version (required for upgrade.php)
exec { 'postfixadmin-seed':
  command => "mysql mailserver -e \"INSERT IGNORE INTO config (name, value) VALUES ('version', '1847');\"",
  unless  => "mysql -umailuser -p${db_pass} -e \"SELECT value FROM mailserver.config WHERE name='version'\" 2>/dev/null | grep -q 1847",
  path    => ['/usr/bin'],
  require => Exec['postfixadmin-schema'],
}

# Mailbox creation hook
file { '/usr/local/bin/postfixadmin-mailbox-postcreate.sh':
  ensure  => file,
  content => "#!/bin/bash\nmkdir -p \"\$4\"\nchown -R vmail:vmail \"\$4\"\nchmod -R 770 \"\$4\"\n",
  mode    => '0755',
  owner   => 'root',
  group   => 'root',
}

# =====================================================
# BACKUP CRON JOB
# =====================================================
file { '/usr/local/bin/backup-mail.sh':
  ensure  => file,
  content => "#!/bin/bash\n# Daily mail backup\nBACKUP_DIR=\"/var/backups/mail\"\nDATE=\$(date +%Y%m%d)\nmkdir -p \$BACKUP_DIR\n\n# Backup MySQL database\nmysqldump -umailuser -p${db_pass} mailserver | gzip > \$BACKUP_DIR/mailserver-\$DATE.sql.gz\n\n# Backup Maildir (incremental via rsync)\nrsync -a --delete /var/mail/vmail/ \$BACKUP_DIR/vmail-latest/\n\n# Keep last 30 days\nfind \$BACKUP_DIR -name 'mailserver-*.sql.gz' -mtime +30 -delete\n\necho \"[\$(date)] Backup completed\" >> /var/log/mail-backup.log\n",
  mode    => '0755',
  owner   => 'root',
}

file { '/var/backups/mail':
  ensure => directory,
  owner  => 'root',
  group  => 'root',
  mode   => '0750',
}

cron { 'mail-backup':
  command => '/usr/local/bin/backup-mail.sh',
  user    => 'root',
  hour    => 2,
  minute  => 17,
  require => [File['/usr/local/bin/backup-mail.sh'], File['/var/backups/mail']],
}

# =====================================================
# LET'S ENCRYPT (instructions — run after DNS is set up)
# =====================================================
file { '/usr/local/bin/get-ssl-cert.sh':
  ensure  => file,
  content => "#!/bin/bash\n# Run this AFTER DNS points to this server:\n#   certbot --nginx -d mail.${domain} -d ${domain}\n#\n# To renew automatically (certbot timer):\n#   systemctl enable certbot.timer\n#   systemctl start certbot.timer\n\necho \"Run: certbot --nginx -d mail.${domain} -d ${domain}\"\n",
  mode    => '0755',
}

# =====================================================
# FIREWALL
# =====================================================
exec { 'ufw-allow-ssh':
  command => 'ufw allow 22/tcp',
  unless  => 'ufw status | grep -q "22/tcp"',
  path    => ['/usr/sbin', '/bin'],
}

exec { 'ufw-allow-mail':
  command => 'ufw allow 25/tcp && ufw allow 587/tcp && ufw allow 143/tcp && ufw allow 993/tcp && ufw allow 110/tcp && ufw allow 995/tcp && ufw allow 4190/tcp',
  unless  => 'ufw status | grep -q "25/tcp"',
  path    => ['/usr/sbin', '/bin'],
}

exec { 'ufw-allow-web':
  command => 'ufw allow 80/tcp && ufw allow 443/tcp',
  unless  => 'ufw status | grep -q "80/tcp"',
  path    => ['/usr/sbin', '/bin'],
}

exec { 'ufw-enable':
  command => 'ufw --force enable',
  unless  => 'ufw status | grep -q "Status: active"',
  path    => ['/usr/sbin', '/bin'],
  require => [Exec['ufw-allow-ssh'], Exec['ufw-allow-mail'], Exec['ufw-allow-web']],
}
