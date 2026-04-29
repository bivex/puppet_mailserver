# Mail Server — Full Corporate Edition
# Includes: Postfix, Dovecot, MySQL virtual users, Roundcube, PostfixAdmin,
#           OpenDKIM, OpenDMARC, SpamAssassin, SPF policy, PostSRSd,
#           Fail2ban (recidive), Sieve, Quotas, Postgrey, HTTPS, MTA-STS,
#           Monitoring, Autodiscover, Backup, TLS hardening
# Run: sudo puppet apply mailserver_full.pp
#
# SECURITY NOTE: Move secrets to Hiera + hiera-eyaml or Vault + puppet-vault_lookup
# before committing to git or using with a Puppet master.

$domain     = 'example.com'
$hostname   = "mail.${domain}"
$ssl_cert   = '/etc/ssl/certs/mail.pem'
$ssl_key    = '/etc/ssl/private/mail.key'
$db_pass    = 'maildbpass123'
$rc_db_pass = 'RcMail2024!Db'
$admin_pass = 'adminpass123'
# Generate: php -r 'echo password_hash("YOUR_SETUP_PASSWORD", PASSWORD_DEFAULT);'
$setup_pw_hash = '$2y$10$pKArZkfRRKyjr0zp3S1GauEPynBCCLXB1R05DpxrMkAXayH.EUqZ6'

# =====================================================
# PACKAGES
# =====================================================
$base_pkgs = [
  'postfix', 'postfix-mysql',
  'dovecot-core', 'dovecot-imapd', 'dovecot-pop3d',
  'dovecot-sieve', 'dovecot-managesieved', 'dovecot-mysql',
  'dovecot-lmtpd',
  'opendkim', 'opendkim-tools',
  'opendmarc',
  'spamassassin', 'spamc', 'razor', 'pyzor',
  'fail2ban', 'mailutils', 'ufw',
  'postgrey',
  'postfix-policyd-spf-python',
  'postsrsd',
]
package { $base_pkgs: ensure => installed }

$web_pkgs = [
  'mariadb-server', 'mariadb-client',
  'curl',
  'nginx', 'php8.3-fpm', 'php8.3-mysql', 'php8.3-mbstring',
  'php8.3-imap', 'php8.3-xml', 'php8.3-curl', 'php8.3-zip',
  'php8.3-gd', 'php8.3-intl',
  'roundcube', 'roundcube-plugins',
  'certbot', 'python3-certbot-nginx',
]
package { $web_pkgs: ensure => installed }

# =====================================================
# SSL SELF-SIGNED CERT (replace with Let's Encrypt for production)
# =====================================================
exec { 'gen-mail-cert':
  command => "openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout ${ssl_key} -out ${ssl_cert} -subj '/CN=${hostname}' -addext 'subjectAltName=DNS:${hostname},DNS:${domain}'",
  creates => $ssl_cert,
  path    => ['/usr/bin', '/usr/sbin'],
}
file { $ssl_key:
  mode  => '0600',
  owner => 'root',
  group => 'root',
}

# DH parameters for PFS
exec { 'gen-dhparam':
  command => 'openssl dhparam -out /etc/postfix/dh2048.pem 2048',
  creates => '/etc/postfix/dh2048.pem',
  path    => ['/usr/bin'],
}

# Sync SSL certs into Postfix chroot
exec { 'sync-ssl-chroot':
  command => 'mkdir -p /var/spool/postfix/etc/ssl/certs /var/spool/postfix/etc/ssl/private && cp /etc/ssl/certs/mail.pem /var/spool/postfix/etc/ssl/certs/ && cp /etc/ssl/private/mail.key /var/spool/postfix/etc/ssl/private/ && chmod 600 /var/spool/postfix/etc/ssl/private/mail.key',
  unless  => 'diff -q /etc/ssl/certs/mail.pem /var/spool/postfix/etc/ssl/certs/mail.pem >/dev/null 2>&1 && diff -q /etc/ssl/private/mail.key /var/spool/postfix/etc/ssl/private/mail.key >/dev/null 2>&1',
  path    => ['/bin', '/usr/bin'],
  require => [Exec['gen-mail-cert'], File[$ssl_key]],
  notify  => Service['postfix'],
}

# =====================================================
# MARIADB + MAIL DATABASE
# =====================================================

# MariaDB tuning
file { '/etc/mysql/mariadb.conf.d/99-tuning.cnf':
  ensure  => file,
  content => "[mysqld]\ninnodb_buffer_pool_size = 256M\nquery_cache_size = 0\nquery_cache_type = 0\n",
  notify  => Service['mariadb'],
  require => Package['mariadb-server'],
}

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

# MariaDB hardening
exec { 'harden-mariadb':
  command => "mysql -e \"DELETE FROM mysql.user WHERE User=''; DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost','127.0.0.1','::1'); DROP DATABASE IF EXISTS test; DELETE FROM mysql.db WHERE Db='test' OR Db='test\\\\_%'; FLUSH PRIVILEGES;\"",
  onlyif  => "mysql -e \"SELECT User FROM mysql.user WHERE User=''\" 2>/dev/null | grep -q .",
  path    => ['/usr/bin'],
  require => Exec['wait-mariadb'],
}

exec { 'create-mail-db':
  command => "mysql -e \"CREATE DATABASE IF NOT EXISTS mailserver CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, DROP, INDEX, ALTER ON mailserver.* TO 'mailuser'@'localhost' IDENTIFIED BY '${db_pass}'; GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, DROP, INDEX, ALTER ON mailserver.* TO 'mailuser'@'127.0.0.1' IDENTIFIED BY '${db_pass}'; FLUSH PRIVILEGES;\"",
  unless  => "mysql -umailuser -p'${db_pass}' -h 127.0.0.1 -e 'USE mailserver' 2>/dev/null",
  path    => ['/usr/bin'],
  require => [Exec['wait-mariadb'], Exec['harden-mariadb']],
}

# Helper script: generates SHA512-CRYPT hashes via PHP crypt() and seeds DB
file { '/usr/local/bin/seed-mail-db.php':
  ensure  => file,
  content => "<?php
\$domain = '${domain}';
\$pass   = '${admin_pass}';
\$salt   = substr(md5(mt_rand()), 0, 16);
\$hash   = crypt(\$pass, '\$6\$' . \$salt . '\$');

\$sql = \"INSERT IGNORE INTO domain (domain,description,aliases,mailboxes,quota,transport,backupmx,created,modified,active)
  VALUES ('\$domain','Default domain',0,0,0,'virtual',0,NOW(),NOW(),1);
INSERT IGNORE INTO admin (username,password,superadmin,created,modified,active)
  VALUES ('admin@\$domain', '\$hash', 1, NOW(), NOW(), 1);
INSERT IGNORE INTO domain_admins (username,domain,created,active)
  VALUES ('admin@\$domain','ALL',NOW(),1);
INSERT IGNORE INTO mailbox (username,password,name,maildir,quota,local_part,domain,created,modified,active)
  VALUES ('admin@\$domain', '\$hash', 'Admin', '\$domain/admin/', 1073741824, 'admin', '\$domain', NOW(), NOW(), 1);
INSERT IGNORE INTO mailbox (username,password,name,maildir,quota,local_part,domain,created,modified,active)
  VALUES ('postmaster@\$domain', '\$hash', 'Postmaster', '\$domain/postmaster/', 1073741824, 'postmaster', '\$domain', NOW(), NOW(), 1);
INSERT IGNORE INTO alias (address,goto,domain,created,modified,active) VALUES ('abuse@\$domain','admin@\$domain','\$domain',NOW(),NOW(),1);
INSERT IGNORE INTO alias (address,goto,domain,created,modified,active) VALUES ('hostmaster@\$domain','admin@\$domain','\$domain',NOW(),NOW(),1);
INSERT IGNORE INTO alias (address,goto,domain,created,modified,active) VALUES ('postmaster@\$domain','admin@\$domain','\$domain',NOW(),NOW(),1);
INSERT IGNORE INTO alias (address,goto,domain,created,modified,active) VALUES ('webmaster@\$domain','admin@\$domain','\$domain',NOW(),NOW(),1);
INSERT IGNORE INTO alias (address,goto,domain,created,modified,active) VALUES ('info@\$domain','admin@\$domain','\$domain',NOW(),NOW(),1);
INSERT IGNORE INTO alias (address,goto,domain,created,modified,active) VALUES ('support@\$domain','admin@\$domain','\$domain',NOW(),NOW(),1);\";
echo \$sql;
",
  mode    => '0600',
  owner   => 'root',
}

# Seed PostfixAdmin tables: domain, admin, mailbox, aliases
# Password scheme: SHA512-CRYPT — must match $CONF['encrypt'] and Dovecot default_pass_scheme
# Uses PHP crypt() for portable hash generation
exec { 'seed-mail-db':
  command => "php /usr/local/bin/seed-mail-db.php | mysql mailserver",
  unless  => "mysql -umailuser -p${db_pass} -e \"SELECT 1 FROM mailserver.domain WHERE domain='${domain}'\" 2>/dev/null | grep -q 1",
  path    => ['/usr/bin'],
  require => [Exec['postfixadmin-schema'], File['/usr/local/bin/seed-mail-db.php']],
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

# KeyTable: selector is "mail" (matches -s mail in opendkim-genkey)
file { '/etc/opendkim/KeyTable':
  ensure  => file,
  content => "mail._domainkey.${domain} ${domain}:mail:/etc/opendkim/keys/mail.private\n",
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
# OPENDMARC
# =====================================================
file { '/etc/opendmarc.conf':
  ensure  => file,
  content => "AuthservID ${hostname}
PidFile /run/opendmarc/opendmarc.pid
RejectFailures false
Syslog yes
Socket inet:8893@localhost
SoftwareHeader true
SPFIgnoreResults false
SPFSelfValidate true
RequiredHeaders false
ReportCommand \"/usr/sbin/sendmail -t\"
",
  notify  => Service['opendmarc'],
}

# OpenDMARC systemd override for RuntimeDirectory
file { '/etc/systemd/system/opendmarc.service.d':
  ensure => directory,
}
file { '/etc/systemd/system/opendmarc.service.d/override.conf':
  ensure  => file,
  content => "[Service]\nRuntimeDirectory=opendmarc\nRuntimeDirectoryMode=0750\n",
  notify  => [Exec['opendmarc-systemd-reload'], Service['opendmarc']],
}
exec { 'opendmarc-systemd-reload':
  command     => 'systemctl daemon-reload',
  refreshonly => true,
  path        => ['/bin', '/usr/bin'],
}

service { 'opendmarc':
  ensure     => running,
  enable     => true,
  hasrestart => true,
  require    => Package['opendmarc'],
}

# =====================================================
# POSTFIX — Virtual Users + MySQL + Hardened
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
smtp_tls_security_level = dane
smtp_tls_mandatory_protocols = !SSLv2 !SSLv3 !TLSv1 !TLSv1.1
smtpd_tls_loglevel = 1
smtpd_tls_mandatory_protocols = !SSLv2 !SSLv3 !TLSv1 !TLSv1.1
smtpd_tls_mandatory_ciphers = high
smtpd_tls_received_header = yes
smtpd_tls_session_cache_timeout = 3600s
smtpd_tls_session_cache_database = btree:\${data_directory}/smtpd_scache
smtp_tls_session_cache_database = btree:\${data_directory}/smtp_scache
smtpd_tls_dh1024_param_file = /etc/postfix/dh2048.pem

# SASL
smtpd_sasl_type = dovecot
smtpd_sasl_path = private/auth
smtpd_sasl_auth_enable = yes
smtpd_sender_login_maps = mysql:/etc/postfix/mysql-virtual-email2email.cf

# SRS (Sender Rewriting Scheme) for forwarded mail
sender_canonical_maps = tcp:127.0.0.1:10001
sender_canonical_classes = envelope_sender
header_checks = regexp:/etc/postfix/header_checks

# Restrictions
smtpd_helo_required = yes
smtpd_client_restrictions = permit_sasl_authenticated, permit_mynetworks, reject_unknown_client_hostname
smtpd_sender_restrictions = permit_sasl_authenticated, permit_mynetworks, reject_authenticated_sender_login_mismatch, reject_non_fqdn_sender, reject_unknown_sender_domain
smtpd_recipient_restrictions = permit_sasl_authenticated, permit_mynetworks, reject_unauth_destination, reject_non_fqdn_recipient, reject_unverified_recipient, check_policy_service unix:private/policyd-spf, check_policy_service inet:127.0.0.1:10023
smtpd_relay_restrictions = permit_sasl_authenticated, permit_mynetworks, reject_unauth_destination
smtpd_data_restrictions = reject_unauth_pipelining
smtpd_end_of_data_restrictions = check_policy_service unix:private/quota-status

# Rate limiting
smtpd_client_message_rate_limit = 100
smtpd_client_recipient_rate_limit = 200
smtpd_client_connection_rate_limit = 60
anvil_rate_time_unit = 60s

# Milters: OpenDKIM (8891) + OpenDMARC (8893)
milter_default_action = accept
milter_protocol = 6
smtpd_milters = inet:localhost:8891, inet:localhost:8893
non_smtpd_milters = inet:localhost:8891, inet:localhost:8893

# Header privacy — configured above (header_checks)

# Postscreen (drops botnets before queue)
postscreen_access_list = permit_mynetworks
postscreen_dnsbl_sites = zen.spamhaus.org*3 bl.spameatingmonkey.net*2 dnsbl.sorbs.net*2
postscreen_dnsbl_threshold = 5
postscreen_greet_action = enforce
postscreen_dnsbl_action = enforce
"

file { '/etc/postfix/main.cf':
  ensure  => file,
  content => $postfix_main,
  notify  => Service['postfix'],
}

# Header checks — strip internal info on outbound
file { '/etc/postfix/header_checks':
  ensure  => file,
  content => "/^Received:\\s+from \\[127\\.0\\.0\\.1\\]/ IGNORE\n/^User-Agent:/ IGNORE\n/^X-Mailer:/ IGNORE\n/^X-Originating-IP:/ IGNORE\n/^X-PHP-Originating-Script:/ IGNORE\n",
  notify  => Service['postfix'],
}

# SPF policy daemon in master.cf
exec { 'master-cf-policyd-spf':
  command => 'grep -q "policyd-spf" /etc/postfix/master.cf || (printf "policyd-spf unix - n n - 0 spawn\n  user=policyd-spf argv=/usr/bin/policyd-spf\n" >> /etc/postfix/master.cf)',
  unless  => 'grep -q "policyd-spf" /etc/postfix/master.cf',
  path    => ['/bin', '/usr/bin'],
  require => Package['postfix-policyd-spf-python'],
  notify  => Service['postfix'],
}

# Increase policyd-spf timeout (default 100s may not be enough)
file { '/etc/postfix-policyd-spf-python/policyd-spf.conf':
  ensure  => file,
  content => "debugLevel = 1\ndefaultSeedOnly = 1\nHELO_reject = Fail\nMail_From_reject = Fail\nPermError_reject = False\nTempError_Defer = False\nskip_addresses = 127.0.0.0/8,::ffff:127.0.0.0//104,::1//128\n",
  require => Package['postfix-policyd-spf-python'],
}

# SpamAssassin transport in master.cf
exec { 'master-cf-spamassassin':
  command => 'grep -q "^spamassassin" /etc/postfix/master.cf || (printf "spamassassin unix -     n       n       -       -       pipe\n  user=debian-spamd argv=/usr/bin/spamc -f -e /usr/sbin/sendmail -oi -f \${sender} \${recipient}\n" >> /etc/postfix/master.cf)',
  unless  => 'grep -q "^spamassassin" /etc/postfix/master.cf',
  path    => ['/bin', '/usr/bin'],
  require => Package['postfix'],
  notify  => Service['postfix'],
}

# Add content_filter to smtp listener
exec { 'master-cf-smtp-filter':
  command => "postconf -M smtp/inet=\"smtp inet n - y - - smtpd -o content_filter=spamassassin\"",
  unless  => "postconf -M smtp/inet | grep -q 'content_filter=spamassassin'",
  path    => ['/usr/sbin', '/usr/bin'],
  require => Package['postfix'],
  notify  => Service['postfix'],
}

exec { 'master-cf-submission':
  command => "postconf -M submission/inet=\"submission inet n - y - - smtpd -o smtpd_tls_security_level=encrypt -o smtpd_sasl_auth_enable=yes -o smtpd_tls_auth_only=yes -o smtpd_sasl_type=dovecot -o smtpd_sasl_path=private/auth -o content_filter=spamassassin\"",
  unless  => "postconf -M submission/inet | grep -q 'smtpd_tls_security_level=encrypt'",
  path    => ['/usr/sbin', '/usr/bin'],
  require => Package['postfix'],
  notify  => Service['postfix'],
}

exec { 'master-cf-submissions':
  command => "postconf -M submissions/inet=\"submissions inet n - y - - smtpd -o smtpd_tls_wrappermode=yes -o smtpd_sasl_auth_enable=yes -o smtpd_tls_security_level=encrypt -o smtpd_sasl_type=dovecot -o smtpd_sasl_path=private/auth -o content_filter=spamassassin\"",
  unless  => "postconf -M submissions/inet | grep -q 'smtpd_tls_wrappermode=yes'",
  path    => ['/usr/sbin', '/usr/bin'],
  require => Package['postfix'],
  notify  => Service['postfix'],
}

service { 'postfix':
  ensure     => running,
  enable     => true,
  hasrestart => true,
  require    => Exec['gen-dhparam'],
}
exec { 'master-cf-pickup':
  command => 'postconf -M pickup/unix="pickup unix n - y 60 1 pickup -o content_filter="',
  unless  => 'postconf -M pickup/unix 2>/dev/null | grep -q "content_filter="',
  path    => ['/usr/sbin', '/usr/bin'],
  notify  => Service['postfix'],
  require => Package['postfix'],
}

exec { 'postfix-unset-global-filter':
  command => 'postconf -X content_filter',
  unless  => 'postconf content_filter 2>/dev/null | grep -q "^content_filter =$" || ! postconf -n content_filter 2>/dev/null | grep -q content_filter',
  path    => ['/usr/sbin', '/usr/bin'],
  notify  => Service['postfix'],
  require => Package['postfix'],
}


# =====================================================
# POSTGREY — greylisting for spam rejection
# =====================================================
service { 'postgrey':
  ensure  => running,
  enable  => true,
  require => Package['postgrey'],
}

# Postgrey whitelist — avoid 5min delay for major providers
file { '/etc/postgrey/whitelist_clients':
  ensure  => file,
  content => "google.com\ngmail.com\noutlook.com\nmicrosoft.com\napple.com\namazonses.com\namazon.com\nyahoo.com\nzoho.com\nmail.ru\nyandex.ru\nicloud.com\nprotonmail.com\nfastmail.com\nsendgrid.net\nmailchimp.com\nmandrillapp.com\nsparkpostmail.com\n",
  require => Package['postgrey'],
  notify  => Service['postgrey'],
}

# =====================================================
# DOVECOT — Virtual Users + MySQL + Quota + Sieve
# =====================================================
file { '/etc/dovecot/dovecot-sql.conf.ext':
  ensure  => file,
  content => "driver = mysql\nconnect = host=127.0.0.1 dbname=mailserver user=mailuser password=${db_pass}\ndefault_pass_scheme = SHA512-CRYPT\npassword_query = SELECT username AS user, password FROM mailbox WHERE username='%u' AND active=1\nuser_query = SELECT CONCAT('/var/mail/vmail/', domain, '/', local_part) AS home, 5000 AS uid, 5000 AS gid, CONCAT('*:bytes=', quota) AS quota_rule FROM mailbox WHERE username='%u' AND active=1\niterate_query = SELECT username AS user FROM mailbox WHERE active=1\n",
  mode    => '0640',
  owner   => 'root',
  group   => 'dovecot',
}

file { '/etc/dovecot/dovecot.conf':
  ensure  => file,
  content => "protocols = imap pop3 lmtp sieve\nmail_location = maildir:/var/mail/vmail/%d/%n/Maildir\nssl = yes\nssl_cert = </etc/ssl/certs/mail.pem\nssl_key = </etc/ssl/private/mail.key\nssl_min_protocol = TLSv1.2\nssl_prefer_server_ciphers = yes\nssl_cipher_list = ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384\nssl_dh = </usr/share/dovecot/dh.pem\ndisable_plaintext_auth = yes\nauth_mechanisms = plain login\nfirst_valid_uid = 5000\nlast_valid_uid = 5000\nfirst_valid_gid = 5000\nlast_valid_gid = 5000\nlogin_trusted_networks = 127.0.0.1\n!include conf.d/*.conf\n",
  notify  => Service['dovecot'],
}

file { '/etc/dovecot/conf.d/10-auth.conf':
  ensure  => file,
  content => "disable_plaintext_auth = yes\nauth_mechanisms = plain login\n!include auth-sql.conf.ext\n\n# Rate-limit failed auth attempts\nauth_failure_delay = 2 secs\n",
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
  content => "plugin {\n  quota = maildir:User quota\n  quota_rule = *:storage=1G\n  quota_rule2 = Trash:storage=+100M\n  quota_grace = 10%%\n}\nprotocol imap {\n  mail_plugins = \$mail_plugins quota imap_quota\n}\nservice quota-status {\n  executable = quota-status -p postfix\n  unix_listener /var/spool/postfix/private/quota-status {\n    mode = 0660\n    user = postfix\n    group = postfix
  }\n  client_limit = 1\n}\n",
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
report_safe 0
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
file { '/etc/fail2ban/filter.d/postfix-sasl.conf':
  ensure  => file,
  content => "[Definition]\nfailregex = ^%%(__prefix_line)swarning: [-._\\w]+\\[<HOST>\\]: SASL (?:LOGIN|PLAIN|(?:CRAM|DIGEST)-MD5) authentication failed:\nignoreregex =\n",
  notify  => Service['fail2ban'],
}

# Fail2ban recidive — ban repeat offenders for 1 week
file { '/etc/fail2ban/jail.d/recidive.conf':
  ensure  => file,
  content => "[recidive]\nenabled  = true\nfilter   = recidive\nbantime  = 1w\nfindtime = 1d\nmaxretry = 3\nlogpath  = /var/log/fail2ban.log\nbackend  = auto\n",
  notify  => Service['fail2ban'],
}

file { '/etc/fail2ban/jail.local':
  ensure  => file,
  content => "[DEFAULT]\nbantime   = 1h\nfindtime  = 10m\nmaxretry  = 5\nbackend   = systemd\nallowipv6 = auto\n\n[sshd]\nenabled  = true\nport     = ssh\nfilter   = sshd\nlogpath  = /var/log/auth.log\n\n[postfix]\nenabled  = true\nport     = smtp,submission\nfilter   = postfix\nlogpath  = /var/log/mail.log\nmaxretry = 3\n\n[postfix-sasl]\nenabled  = true\nport     = smtp,submission\nfilter   = postfix-sasl\nlogpath  = /var/log/mail.log\nmaxretry = 3\nbantime  = 24h\n\n[dovecot]\nenabled  = true\nport     = pop3,pop3s,imap,imaps,submission\nfilter   = dovecot\nlogpath  = /var/log/mail.log\nmaxretry = 3\n\n[sieve]\nenabled  = true\nport     = 4190\nfilter   = dovecot\nlogpath  = /var/log/mail.log\nmaxretry = 3\n",
  notify  => Service['fail2ban'],
}

service { 'fail2ban':
  ensure     => running,
  enable     => true,
  hasrestart => true,
}

# =====================================================
# NGINX + PHP-FPM + HTTPS
# =====================================================

# PHP tuning
exec { 'php-fpm-tuning':
  command => "sed -i 's/^pm = .*/pm = ondemand/' /etc/php/8.3/fpm/pool.d/www.conf && sed -i 's/^pm.max_children = .*/pm.max_children = 50/' /etc/php/8.3/fpm/pool.d/www.conf && sed -i 's/;session.gc_maxlifetime = .*/session.gc_maxlifetime = 14400/' /etc/php/8.3/fpm/php.ini",
  unless  => "grep -q 'pm = ondemand' /etc/php/8.3/fpm/pool.d/www.conf",
  path    => ['/usr/bin', '/bin'],
  notify  => Service['php8.3-fpm'],
  require => Package['php8.3-fpm'],
}

service { 'php8.3-fpm':
  ensure => running,
  enable => true,
}

file { '/etc/nginx/sites-available/mail.conf':
  ensure  => file,
  content => "limit_req_zone \$binary_remote_addr zone=login:10m rate=5r/m;\n\nserver {\n  listen 80;\n  listen [::]:80;\n  server_name ${hostname} ${domain} autodiscover.${domain} autoconfig.${domain};\n  root /var/www/html;\n\n  # Let's Encrypt\n  location /.well-known/acme-challenge/ {\n    root /var/www/html;\n  }\n\n  location / {\n    return 301 https://\$host\$request_uri;\n  }\n}\n\nserver {\n  listen 443 ssl;\n  listen [::]:443 ssl;\n  server_name ${hostname} ${domain} autodiscover.${domain} autoconfig.${domain};\n  root /var/www/html;\n\n  ssl_certificate ${ssl_cert};\n  ssl_certificate_key ${ssl_key};\n  ssl_protocols TLSv1.2 TLSv1.3;\n  ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;\n  ssl_prefer_server_ciphers on;\n  ssl_stapling on;\n  ssl_stapling_verify on;\n  resolver 8.8.8.8 8.8.4.4 valid=300s;\n  resolver_timeout 5s;\n  ssl_session_cache shared:SSL:10m;\n  ssl_session_timeout 10m;\n\n  # Security headers\n  add_header Strict-Transport-Security \"max-age=63072000; includeSubDomains\" always;\n  add_header X-Frame-Options \"SAMEORIGIN\" always;\n  add_header X-Content-Type-Options \"nosniff\" always;\n  add_header X-Robots-Tag \"noindex, nofollow\" always;\n  add_header Referrer-Policy \"strict-origin-when-cross-origin\" always;\n\n\n  # Let's Encrypt renewal\n  location /.well-known/acme-challenge/ {\n    root /var/www/html;\n  }\n\n  # MTA-STS policy\n  location /.well-known/mta-sts.txt {\n    default_type text/plain;\n    return 200 'version: STSv1\\nmode: testing\\nmax_age: 604800\\nmx: ${hostname}\\n';\n  }\n\n  # Roundcube webmail\n  location /mail {\n    alias /var/lib/roundcube;\n    index index.php;\n    location ~ ^/mail/(.+\\.php)(.*)$ {\n      include fastcgi_params;\n      fastcgi_read_timeout 900s;\n      fastcgi_pass unix:/run/php/php8.3-fpm.sock;\n      fastcgi_param SCRIPT_FILENAME \$request_filename;\n      fastcgi_param HTTPS on;\n    }\n    location ~ ^/mail/(.*)$ {\n      alias /var/lib/roundcube/\$1;\n    }\n  }\n\n  # PostfixAdmin\n  location /admin {\n    alias /opt/postfixadmin/public/;\n    index index.php;\n    if (!-e \$request_filename) { rewrite ^/admin/(.*)$ /admin/index.php?\$1 last; }\n  }\n\n  # Block setup.php — localhost only\n  location ~ ^/admin/setup\\.php\$ {\n    alias /opt/postfixadmin/public/;\n    allow 127.0.0.1;\n    allow ::1;\n    deny all;\n    limit_req zone=login burst=5 nodelay;\n    fastcgi_pass unix:/run/php/php8.3-fpm.sock;\n    fastcgi_param SCRIPT_FILENAME /opt/postfixadmin/public/setup.php;\n    fastcgi_param HTTPS on;\n    include fastcgi_params;\n    fastcgi_read_timeout 900s;\n  }\n\n  location ~ ^/admin/(.+\\.php)$ {\n    alias /opt/postfixadmin/public/;\n    limit_req zone=login burst=5 nodelay;\n    fastcgi_pass unix:/run/php/php8.3-fpm.sock;\n    fastcgi_param SCRIPT_FILENAME /opt/postfixadmin/public/\$1;\n    fastcgi_param HTTPS on;\n    include fastcgi_params;\n      fastcgi_read_timeout 900s;\n  }\n\n  # Autodiscover (Outlook)\n  location /autodiscover/autodiscover.xml {\n    fastcgi_pass unix:/run/php/php8.3-fpm.sock;\n    include fastcgi_params;\n      fastcgi_read_timeout 900s;\n    fastcgi_param SCRIPT_FILENAME /var/www/html/autodiscover.php;\n    fastcgi_param HTTPS on;\n  }\n\n  # Autoconfig (Thunderbird)\n  location /.well-known/autoconfig/mail/config-v1.1.xml {\n    default_type application/xml;\n    return 200 '<?xml version=\"1.0\"?><clientConfig version=\"1.1\"><emailProvider id=\"${domain}\"><domain>${domain}</domain><displayName>Mail</displayName><incomingServer type=\"imap\"><hostname>${hostname}</hostname><port>993</port><socketType>SSL</socketType><username>%EMAILADDRESS%</username><authentication>password-cleartext</authentication></incomingServer><incomingServer type=\"pop3\"><hostname>${hostname}</hostname><port>995</port><socketType>SSL</socketType><username>%EMAILADDRESS%</username><authentication>password-cleartext</authentication></incomingServer><outgoingServer type=\"smtp\"><hostname>${hostname}</hostname><port>587</port><socketType>STARTTLS</socketType><username>%EMAILADDRESS%</username><authentication>password-cleartext</authentication></outgoingServer></emailProvider></clientConfig>';\n  }\n}\n",
  notify  => Service['nginx'],
}

file { '/etc/nginx/sites-enabled/mail.conf':
  ensure => link,
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
# des_key should be unique per installation — change for production
file { '/etc/roundcube/config.inc.php':
  ensure  => file,
  content => "<?php\n\$config['db_dsnw'] = 'mysql://roundcube:${rc_db_pass}@localhost/roundcube';\n\$config['imap_host'] = 'ssl://localhost:993';\n\$config['smtp_host'] = 'tls://localhost:587';\n\$config['smtp_user'] = '%u';\n\$config['smtp_pass'] = '%p';\n\$config['support_url'] = 'mailto:postmaster@${domain}';\n\$config['product_name'] = 'Corporate Mail';\n\$config['des_key'] = 'fm9XJ23vKpLq7wBnRtYcMdAu';\n\$config['plugins'] = ['archive','zipdownload','managesieve','markasjunk','newmail_notifier','twofactor_gauthenticator','password','new_user_identity'];\n\$config['language'] = 'en_US';\n\$config['enable_installer'] = false;\n\n// UI defaults\n\$config['skin'] = 'elastic';\n\$config['layout'] = 'widescreen';\n\$config['preview_pane'] = true;\n\$config['htmleditor'] = 1;\n\$config['show_images'] = 1;\n\$config['default_font'] = 'Verdana';\n\$config['date_format'] = 'Y-m-d';\n\$config['time_format'] = 'H:i';\n\$config['draft_autosave'] = 300;\n\$config['create_default_folders'] = true;\n\$config['default_imap_folders'] = ['INBOX', 'Sent', 'Drafts', 'Junk', 'Trash'];\n\$config['mime_param_folding'] = 1;\n\$config['request_mdn'] = true;\n\$config['mdn_default'] = false;\n\$config['dsn_default'] = false;\n\n// Identity — auto-create from login email\n\$config['email_dns_check'] = false;\n\n// SSL bypass for self-signed certs — REMOVE after installing Let's Encrypt\n\$config['imap_conn_options'] = array('ssl' => array('verify_peer' => false, 'verify_peer_name' => false, 'allow_self_signed' => true));\n\$config['smtp_conn_options'] = array('ssl' => array('verify_peer' => false, 'verify_peer_name' => false, 'allow_self_signed' => true));\n\$config['managesieve_conn_options'] = array('ssl' => array('verify_peer' => false, 'verify_peer_name' => false, 'allow_self_signed' => true));\n\n// Session security\n\$config['ip_check'] = false;\n\$config['sess_lifetime'] = 30;\n?>",
  require => Package['roundcube'],
}

# Roundcube database — stronger password
exec { 'roundcube-db':
  command => "mysql -e \"CREATE DATABASE IF NOT EXISTS roundcube CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, DROP, INDEX, ALTER ON roundcube.* TO 'roundcube'@'localhost' IDENTIFIED BY '${rc_db_pass}'; GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, DROP, INDEX, ALTER ON roundcube.* TO 'roundcube'@'127.0.0.1' IDENTIFIED BY '${rc_db_pass}'; FLUSH PRIVILEGES;\"",
  unless  => "mysql -uroundcube -p'${rc_db_pass}' -h 127.0.0.1 -e 'USE roundcube' 2>/dev/null",
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

# Roundcube managesieve plugin config — vacation + forward + filters
file { '/etc/roundcube/plugins/managesieve/config.inc.php':
  ensure  => file,
  content => "<?php\n\$config['managesieve_host'] = 'localhost';\n\$config['managesieve_port'] = 4190;\n\$config['managesieve_auth_type'] = '';\n\n// Vacation (Out of Office) — enable with sensible defaults\n\$config['managesieve_vacation'] = 1;\n\$config['managesieve_vacation_interval'] = 1;\n\$config['managesieve_vacation_addresses_init'] = true;\n\$config['managesieve_vacation_from_init'] = true;\n\n// Vacation form defaults (requires patch to rcube_sieve_vacation.php)\n\$config['managesieve_vacation_default_subject'] = 'Out of Office';\n\$config['managesieve_vacation_default_body'] = 'I am currently out of the office and will respond to your email upon my return.\\n\\nFor urgent matters, please contact support@${domain}.';\n\n// Forward / redirect\n\$config['managesieve_forward'] = 1;\n\n// Default sieve script for new users\n\$config['managesieve_default'] = '/etc/dovecot/sieve/default.sieve';\n\n// Script name on server\n\$config['managesieve_script_name'] = 'managesieve';\n\$config['managesieve_filename_extension'] = '.sieve';\n\$config['managesieve_debug'] = false;\n\$config['managesieve_replace_delimiter'] = '';\n\$config['managesieve_disabled_extensions'] = [];\n\$config['managesieve_kolab_master'] = false;\n\n// Headers shown in filter rules\n\$config['managesieve_default_headers'] = ['Subject', 'From', 'To', 'Cc'];\n?>",
  require => Package['roundcube-plugins'],
}

# Patch managesieve vacation form with default subject/body from config
$vacation_patch = '/usr/share/roundcube/plugins/managesieve/lib/Roundcube/rcube_sieve_vacation.php'
exec { 'patch-managesieve-vacation':
  command => "python3 -c \"
f = '${vacation_patch}'
with open(f, 'r') as fh: content = fh.read()
old = '''            if (\\\$from_addr) {
                \\\$default_identity = \\\$this->rc->user->list_emails(true);
                \\\$this->vacation['from'] = format_email_recipient(\\\$default_identity['email'], \\\$default_identity['name']);
            }
        }'''
new = '''            if (\\\$from_addr) {
                \\\$default_identity = \\\$this->rc->user->list_emails(true);
                \\\$this->vacation['from'] = format_email_recipient(\\\$default_identity['email'], \\\$default_identity['name']);
            }
            if (empty(\\\$this->vacation['subject'])):
                \\\$this->vacation['subject'] = \\\$this->rc->config->get('managesieve_vacation_default_subject', 'Out of Office');
            endif;
            if (empty(\\\$this->vacation['reason'])):
                \\\$this->vacation['reason'] = \\\$this->rc->config->get('managesieve_vacation_default_body', 'I am currently out of the office.');
            endif;
        }'''
if old in content:
    content = content.replace(old, new, 1)
    with open(f, 'w') as fh: fh.write(content)
    print('Patched')
else:
    print('Already patched or pattern changed')
\"",
  unless  => "grep -q 'managesieve_vacation_default_subject' ${vacation_patch}",
  path    => ['/usr/bin'],
  require => [File['/etc/roundcube/plugins/managesieve/config.inc.php'], Package['roundcube-plugins']],
}

# Roundcube password plugin — allow users to change mail password
file { '/etc/roundcube/plugins/password/config.inc.php':
  ensure  => file,
  content => "<?php\n\$config['password_driver'] = 'sql';\n\$config['password_db_dsn'] = 'mysql://mailuser:${db_pass}@127.0.0.1/mailserver';\n\$config['password_query'] = 'UPDATE mailbox SET password=%P WHERE username=%u AND active=1';\n\$config['password_crypt_hash'] = 'sha512';\n\$config['password_hash_algorithm'] = 'sha512';\n\$config['password_hash_base64'] = false;\n\$config['password_minimum_length'] = 8;\n\$config['password_require_nonalpha'] = false;\n?>",
  require => Package['roundcube-plugins'],
}

# Roundcube newmail_notifier — desktop + sound notifications
file { '/etc/roundcube/plugins/newmail_notifier/config.inc.php':
  ensure  => file,
  content => "<?php\n// Desktop notification on new mail\n\$config['newmail_notifier_desktop'] = true;\n// Sound notification\n\$config['newmail_notifier_sound'] = true;\n// Check interval in seconds (default 60)\n\$config['newmail_notifier_check_interval'] = 60;\n?>",
  require => Package['roundcube-plugins'],
}

# Roundcube markasjunk plugin config
file { '/etc/roundcube/plugins/markasjunk/config.inc.php':
  ensure  => file,
  content => "<?php\n// Move to Junk folder on mark as spam\n\$config['markasjunk_learning_driver'] = 'cmd_learn';\n\$config['markasjunk_spam_cmd'] = 'sa-learn --spam --username=%u --no-sync';\n\$config['markasjunk_ham_cmd'] = 'sa-learn --ham --username=%u --no-sync';\n?>",
  require => Package['roundcube-plugins'],
}

# =====================================================
# 2FA — Roundcube TOTP (twofactor_gauthenticator from GitHub)
# =====================================================

# Install plugin from GitHub (not in Ubuntu packages)
# Ubuntu package uses INSTALL_PATH=/var/lib/roundcube/ so plugins must go there
exec { 'install-roundcube-2fa-plugin':
  command => "git clone https://github.com/alexandregz/twofactor_gauthenticator.git /var/lib/roundcube/plugins/twofactor_gauthenticator && chown -R root:root /var/lib/roundcube/plugins/twofactor_gauthenticator",
  unless  => "test -f /var/lib/roundcube/plugins/twofactor_gauthenticator/twofactor_gauthenticator.php",
  path    => ['/usr/bin', '/usr/sbin'],
  require => Package['roundcube'],
}

# Remove duplicate from /usr/share if roundcube package ships it there
exec { 'remove-duplicate-2fa-plugin':
  command => 'rm -rf /usr/share/roundcube/plugins/twofactor_gauthenticator',
  onlyif  => 'test -d /usr/share/roundcube/plugins/twofactor_gauthenticator',
  path    => ['/bin', '/usr/bin'],
  require => Exec['install-roundcube-2fa-plugin'],
}

# Patch: add 2FA link to Roundcube settings navigation
file { '/usr/local/bin/patch-roundcube-2fa-nav.py':
  ensure  => file,
  content => "#!/usr/bin/env python3
import sys

f = '/var/lib/roundcube/plugins/twofactor_gauthenticator/twofactor_gauthenticator.php'
with open(f, 'r') as fh:
    content = fh.read()

if 'settings_actions' in content:
    print('Already patched')
    sys.exit(0)

old = \"\$this->add_texts('localization/', true);\"
new = \"\"\"\$this->add_texts('localization/', true);

        // Add 2FA link to settings navigation
        \$this->add_hook('settings_actions', [\$this, 'settings_actions']);\"\"\"

if old in content:
    content = content.replace(old, new, 1)
else:
    print('Pattern not found')
    sys.exit(1)

# Add settings_actions method before closing brace
method = '''
    function settings_actions(\$args)
    {
        \$this->add_texts('localization/');
        \$args['actions'][] = [
            'action' => 'twofactor_gauthenticator',
            'class'  => 'twofactor',
            'label'  => 'twofactor_gauthenticator',
            'title'  => 'twofactor_gauthenticator',
            'domain' => 'twofactor_gauthenticator',
        ];
        return \$args;
    }
'''
last_brace = content.rfind('}')
content = content[:last_brace] + method + '\\n}'

with open(f, 'w') as fh:
    fh.write(content)
print('Patched successfully')
",
  mode    => '0755',
  owner   => 'root',
}

exec { 'patch-roundcube-2fa-nav':
  command => 'python3 /usr/local/bin/patch-roundcube-2fa-nav.py',
  unless  => "grep -q 'settings_actions' /var/lib/roundcube/plugins/twofactor_gauthenticator/twofactor_gauthenticator.php",
  path    => ['/usr/bin'],
  require => [Exec['install-roundcube-2fa-plugin'], File['/usr/local/bin/patch-roundcube-2fa-nav.py']],
}

file { '/etc/roundcube/plugins/twofactor_gauthenticator':
  ensure => directory,
  require => Exec['install-roundcube-2fa-plugin'],
}

# Config uses $rcmail_config (not $config) — plugin-specific format
# TOTP secrets stored in roundcube.userprefs (no extra table needed)
file { '/etc/roundcube/plugins/twofactor_gauthenticator/config.inc.php':
  ensure  => file,
  content => "<?php
// 2FA TOTP configuration for Roundcube
// Force all users to set up 2FA on first login (false = optional)
\$rcmail_config['force_enrollment_users'] = false;

// IPs allowed to bypass 2FA
\$rcmail_config['whitelist'] = array('127.0.0.0/8', '::1');

// Allow 'remember this device for 30 days'
\$rcmail_config['allow_save_device_30days'] = true;

// Show TOTP field as password dots
\$rcmail_config['twofactor_formfield_as_password'] = true;

// All users allowed (null = everyone, array = only listed)
\$rcmail_config['users_allowed_2FA'] = null;

// Log failed 2FA attempts
\$rcmail_config['enable_fail_logs'] = true;

// Encrypt stored secrets with Roundcube DES key
\$rcmail_config['twofactor_pref_encrypt'] = true;
?>",
  require => File['/etc/roundcube/plugins/twofactor_gauthenticator'],
}

# =====================================================
# 2FA — PostfixAdmin TOTP via twofactor_gauthenticator
# =====================================================

# PostfixAdmin stores TOTP in its own 'totp' table
exec { 'postfixadmin-totp-table':
  command => "mysql mailserver -e \"
CREATE TABLE IF NOT EXISTS totp (
  id int(11) NOT NULL AUTO_INCREMENT,
  username varchar(255) NOT NULL,
  secret varchar(255) NOT NULL,
  recovery_codes text,
  enabled tinyint(1) NOT NULL DEFAULT 0,
  created datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY username (username)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
\"",
  unless  => "mysql -e \"SELECT 1 FROM information_schema.tables WHERE table_schema='mailserver' AND table_name='totp'\" 2>/dev/null | grep -q 1",
  path    => ['/usr/bin'],
  require => Exec['postfixadmin-schema'],
}

# PostfixAdmin 4.0.1 — install from GitHub (not Ubuntu package which is 3.3.x)
exec { 'install-postfixadmin':
  command => "curl -sL https://api.github.com/repos/postfixadmin/postfixadmin/tarball/v4.0.1 | tar xz --strip-components=1 -C /opt/postfixadmin && cd /opt/postfixadmin && COMPOSER_ALLOW_SUPERUSER=1 HOME=/root bash install.sh && chown -R www-data:www-data /opt/postfixadmin/templates_c",
  creates => '/opt/postfixadmin/vendor/autoload.php',
  path    => ['/usr/bin', '/bin'],
  require => [Package['curl'], File['/opt/postfixadmin']],
}

file { '/opt/postfixadmin':
  ensure => directory,
  owner  => 'root',
  group  => 'www-data',
}

file { '/opt/postfixadmin/templates_c':
  ensure => directory,
  owner  => 'www-data',
  group  => 'www-data',
  mode   => '0770',
  require => Exec['install-postfixadmin'],
}

# Config: link from /etc into install dir
file { '/opt/postfixadmin/config.local.php':
  ensure => symlink,
  target => '/etc/postfixadmin/config.local.php',
  require => Exec['install-postfixadmin'],
}

file { '/etc/postfixadmin':
  ensure => directory,
}

# PostfixAdmin config: enable 2FA
file { '/etc/postfixadmin/config.local.php':
  ensure  => file,
  content => "<?php\n\$CONF['configured'] = true;\n\$CONF['encrypt'] = 'php_crypt:SHA512';\n\$CONF['database_type'] = 'mysqli';\n\$CONF['database_host'] = 'localhost';\n\$CONF['database_user'] = 'mailuser';\n\$CONF['database_password'] = '${db_pass}';\n\$CONF['database_name'] = 'mailserver';\n\$CONF['admin_email'] = 'postmaster@${domain}';\n\$CONF['default_aliases'] = array('abuse' => 'admin@${domain}', 'hostmaster' => 'admin@${domain}', 'postmaster' => 'admin@${domain}', 'webmaster' => 'admin@${domain}');\n\$CONF['domain_path'] = 'YES';\n\$CONF['domain_in_mailbox'] = 'NO';\n\$CONF['mailbox_postcreation_script'] = 'sudo /usr/local/bin/postfixadmin-mailbox-postcreate.sh';\n\$CONF['fetchmail'] = 'NO';\n\$CONF['show_footer_text'] = 'NO';\n\$CONF['quota'] = 'YES';\n\$CONF['used_quotas'] = 'YES';\n\$CONF['new_quota_table'] = 'YES';\n\$CONF['vacation'] = 'NO';\n\$CONF['password_expiration'] = 'NO';\n\n// Setup password — required for /admin/setup.php\n\$CONF['setup_password'] = '${setup_pw_hash}';\n\n// 2FA / TOTP\n\$CONF['totp'] = 'YES';\n\$CONF['totp_admin'] = 'YES';\n\$CONF['totp_user'] = 'YES';\n?>",
  require => File['/etc/postfixadmin'],
}

# Rate-limit PostfixAdmin login page in Nginx (stricter for admin panel)
# Already present: limit_req zone=login burst=5 nodelay on /admin location

# =====================================================
# POSTFIXADMIN SCHEMA
# =====================================================

# PostfixAdmin schema — created by upgrade.php on first run
exec { 'postfixadmin-schema':
  command => "cd /opt/postfixadmin && php public/upgrade.php",
  creates => '/opt/postfixadmin/.schema-initialized',
  path    => ['/usr/bin'],
  require => [Exec['create-mail-db'], File['/etc/postfixadmin/config.local.php'], Exec['install-postfixadmin']],
}

# Mark schema as initialized
file { '/opt/postfixadmin/.schema-initialized':
  ensure  => file,
  content => '4.0.1',
  require => Exec['postfixadmin-schema'],
}

# Mailbox creation hook + sudoers for www-data
file { '/usr/local/bin/postfixadmin-mailbox-postcreate.sh':
  ensure  => file,
  content => "#!/bin/bash\nmkdir -p \"\$4\"\nchown -R vmail:vmail \"\$4\"\nchmod -R 770 \"\$4\"\n",
  mode    => '0755',
  owner   => 'root',
  group   => 'root',
}

file { '/etc/sudoers.d/postfixadmin-maildir':
  ensure  => file,
  content => "www-data ALL=(root) NOPASSWD: /usr/local/bin/postfixadmin-mailbox-postcreate.sh\n",
  mode    => '0440',
  owner   => 'root',
}

# =====================================================
# LOGROTATE
# =====================================================
file { '/etc/logrotate.d/mail':
  ensure  => file,
  content => "/var/log/mail.log {\n  weekly\n  rotate 12\n  compress\n  delaycompress\n  missingok\n  notifempty\n  create 0640 root adm\n  postrotate\n    invoke-rc.d rsyslog rotate >/dev/null 2>&1 || true\n  endscript\n}\n\n/var/log/mail-backup.log {\n  monthly\n  rotate 6\n  compress\n  missingok\n  notifempty\n}\n",
}

# =====================================================
# MONITORING — health check script
# =====================================================
file { '/usr/local/bin/mail-healthcheck.sh':
  ensure  => file,
  content => "#!/bin/bash\n# Mail server health check — runs every 10 min via cron\nMAILTO=\"postmaster@${domain}\"\nFAILED=''\n\nfor svc in postfix dovecot nginx opendkim opendmarc mariadb php8.3-fpm fail2ban postgrey spamd; do\n  systemctl is-active --quiet \$svc || FAILED=\"\$FAILED \$svc\"\ndone\n\n# Check SMTP port\nnc -z -w5 localhost 25 >/dev/null 2>&1 || FAILED=\"\$FAILED smtp:25\"\nnc -z -w5 localhost 587 >/dev/null 2>&1 || FAILED=\"\$FAILED submission:587\"\nnc -z -w5 localhost 993 >/dev/null 2>&1 || FAILED=\"\$FAILED imaps:993\"\n\n# Check MySQL connectivity (using credentials file)\nmysql --defaults-extra-file=/root/.my-backup.cnf -e 'SELECT 1' mailserver >/dev/null 2>&1 || FAILED=\"\$FAILED mysql\"\n\n# Check queue size\nQSIZE=\$(mailq 2>/dev/null | tail -1 | awk '{print \$5}')\nif [ -n \"\$QSIZE\" ] && [ \"\$QSIZE\" -gt 500 ] 2>/dev/null; then\n  FAILED=\"\$FAILED queue_high:\$QSIZE\"\nfi\n\n# Check disk space (<10% free triggers alert)\nDFREE=\$(df /var/mail/vmail --output=pcent | tail -1 | tr -d ' %')\nif [ -n \"\$DFREE\" ] && [ \"\$DFREE\" -gt 90 ] 2>/dev/null; then\n  FAILED=\"\$FAILED disk_\${DFREE}%25_used\"\nfi\n\n# Check SSL cert expiry (<14 days triggers alert)\nif openssl x509 -checkend 1209600 -noout -in ${ssl_cert} 2>/dev/null; then\n  : # cert OK\nelse\n  FAILED=\"\$FAILED ssl_expiring_soon\"\nfi\n\nif [ -n \"\$FAILED\" ]; then\n  echo \"[\$(date)] ALERT: services down:\$FAILED on \$(hostname)\" >> /var/log/mail-healthcheck.log\n  logger -p mail.error \"mail-healthcheck: services down:\$FAILED\"\n  echo \"ALERT on \$(hostname): services down:\$FAILED\" | mail -s \"[MAIL ALERT] \$(hostname) — services down\" \$MAILTO\nfi\n",
  mode    => '0755',
  owner   => 'root',
  group   => 'root',
}

cron { 'mail-healthcheck':
  command => '/usr/local/bin/mail-healthcheck.sh',
  user    => 'root',
  minute  => '*/10',
  require => File['/usr/local/bin/mail-healthcheck.sh'],
}

# =====================================================
# DNS RECORDS TEMPLATE (copy-paste to DNS provider)
# =====================================================
file { '/root/dns-records.txt':
  ensure  => file,
  content => "# DNS records for ${domain} — add these to your DNS provider
# ============================================================

# MX record — mail exchange
MX     10 mail.${domain}.

# A record — mail server IP
A      mail.${domain}.  YOUR_SERVER_IP

# SPF — authorize this server to send mail
TXT    ${domain}.  \"v=spf1 mx a ip4:YOUR_SERVER_IP ~all\"

# DKIM — public key from OpenDKIM (get actual key: sudo cat /etc/opendkim/keys/mail.txt)
TXT    mail._domainkey.${domain}.  \"v=DKIM1; h=sha256; k=rsa; p=<YOUR_DKIM_KEY — run: sudo cat /etc/opendkim/keys/mail.txt>\"

# DMARC — policy for failed SPF/DKIM
TXT    _dmarc.${domain}.  \"v=DMARC1; p=quarantine; rua=mailto:postmaster@${domain}; ruf=mailto:postmaster@${domain}; fo=1\"

# CAA records for Let's Encrypt
@ IN CAA 0 issue \"letsencrypt.org\"
@ IN CAA 0 issuewild \";\"

# BIMI (Brand Indicators)
default._bimi.${domain} IN TXT \"v=BIMI1; l=https://mail.${domain}/logo.svg; a=self;\"

# MTA-STS — signal TLS support (RFC 8461)
TXT    _mta-sts.${domain}.  \"v=STSv1; id=2026042801\"

# TLS-RPT — reporting endpoint for TLS failures
TXT    _smtp._tls.${domain}.  \"v=TLSRPTv1; rua=mailto:postmaster@${domain}\"

# Reverse DNS (PTR) — set at your hosting provider
PTR    YOUR_SERVER_IP  ->  mail.${domain}.

# Autodiscover SRV for Outlook
SRV    _autodiscover._tcp.${domain}.  0 443 autodiscover.${domain}.

# Autoconfig CNAME (optional)
CNAME  autoconfig.${domain}.  mail.${domain}.

# DANE/TLSA — requires fixed SSL cert (not Let's Encrypt auto-renewal)
# Generate after cert is stable: openssl x509 -in ${ssl_cert} -outform DER | openssl sha256
# TLSA  _25._tcp.mail.${domain}.  3 1 1 <SHA256_HASH>
",
}

# =====================================================
# BACKUP — with credential file (not exposed in ps aux)
# =====================================================
file { '/root/.my-backup.cnf':
  ensure  => file,
  content => "[client]\nuser = mailuser\npassword = ${db_pass}\nhost = localhost\n",
  mode    => '0600',
  owner   => 'root',
  group   => 'root',
}

file { '/usr/local/bin/backup-mail.sh':
  ensure  => file,
  content => "#!/bin/bash\n# Daily mail backup\nBACKUP_DIR=\"/var/backups/mail\"\nDATE=\$(date +%Y%m%d)\nmkdir -p \$BACKUP_DIR\n\n# Backup MySQL database (password from file, not args)\nmysqldump --defaults-extra-file=/root/.my-backup.cnf mailserver | gzip > \$BACKUP_DIR/mailserver-\$DATE.sql.gz\n\n# Backup Maildir (incremental via rsync)\nrsync -a --delete /var/mail/vmail/ \$BACKUP_DIR/vmail-latest/\n\n# Keep last 30 days\nfind \$BACKUP_DIR -name 'mailserver-*.sql.gz' -mtime +30 -delete\n\necho \"[\$(date)] Backup completed\" >> /var/log/mail-backup.log\n",
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
  require => [File['/usr/local/bin/backup-mail.sh'], File['/var/backups/mail'], File['/root/.my-backup.cnf']],
}

# =====================================================
# LET'S ENCRYPT (instructions — run after DNS is set up)
# =====================================================
file { '/usr/local/bin/get-ssl-cert.sh':
  ensure  => file,
  content => "#!/bin/bash
# Run this AFTER DNS points to this server:
#   certbot --nginx -d mail.${domain} -d ${domain}

if certbot --nginx -d mail.${domain} -d ${domain}; then
  echo \"Certificate installed. Cleaning up Roundcube security bypasses...\"
  sed -i \"s/'verify_peer' => false/'verify_peer' => true/g\" /etc/roundcube/config.inc.php
  sed -i \"s/'verify_peer_name' => false/'verify_peer_name' => true/g\" /etc/roundcube/config.inc.php
  sed -i \"s/'allow_self_signed' => true/'allow_self_signed' => false/g\" /etc/roundcube/config.inc.php
  systemctl restart nginx
else
  echo \"Certbot failed. Check DNS and try again.\"
fi
",
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

# Each port gets its own unless check
$ufw_ports = ['25/tcp', '587/tcp', '465/tcp', '143/tcp', '993/tcp', '110/tcp', '995/tcp', '4190/tcp']
$ufw_ports.each |$port| {
  exec { "ufw-allow-${port}":
    command => "ufw allow ${port}",
    unless  => "ufw status | grep -q '${port}'",
    path    => ['/usr/sbin', '/bin'],
  }
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
  require => [Exec['ufw-allow-ssh'], Exec['ufw-allow-web']],
}

