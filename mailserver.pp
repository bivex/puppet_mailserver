# Mail Server - Corporate Edition (tested on Ubuntu 24.04 ARM64)
# Includes: Postfix, Dovecot, OpenDKIM, SpamAssassin, Fail2ban, Sieve
# Run: sudo puppet apply mailserver.pp

$domain   = 'example.com'
$ssl_cert = '/etc/ssl/certs/mail.pem'
$ssl_key  = '/etc/ssl/private/mail.key'
$hostname = "mail.${domain}"

# =====================================================
# PACKAGES
# =====================================================
$pkgs = [
  'postfix',
  'dovecot-core',
  'dovecot-imapd',
  'dovecot-pop3d',
  'dovecot-sieve',
  'dovecot-managesieved',
  'opendkim',
  'opendkim-tools',
  'spamassassin',
  'spamc',
  'fail2ban',
  'mailutils',
  'ufw',
]
package { $pkgs: ensure => installed }

# =====================================================
# SSL SELF-SIGNED CERTIFICATE
# =====================================================
exec { 'gen-mail-cert':
  command => "openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout ${ssl_key} -out ${ssl_cert} -subj '/CN=${hostname}'",
  creates => $ssl_cert,
  path    => ['/usr/bin', '/usr/sbin'],
  require => Package['postfix'],
}
file { $ssl_key:
  mode    => '0600',
  owner   => 'root',
  group   => 'root',
  require => Exec['gen-mail-cert'],
}

# =====================================================
# OPENDKIM - mail signing/verification
# =====================================================
file { '/etc/opendkim.conf':
  ensure  => file,
  content => "AutoRestart             Yes
AutoRestartRate         10/1h
Syslog                  yes
SyslogSuccess           yes
LogWhy                  yes
Canonicalization        relaxed/simple
Mode                    sv
SubDomains              no
OversignHeaders         From
SignatureAlgorithm      rsa-sha256
UserID                  opendkim
Socket                  inet:8891@localhost
PidFile                 /run/opendkim/opendkim.pid
UMask                   007
ExternalIgnoreList      refile:/etc/opendkim/TrustedHosts
InternalHosts           refile:/etc/opendkim/TrustedHosts
KeyTable                refile:/etc/opendkim/KeyTable
SigningTable             refile:/etc/opendkim/SigningTable
",
  require => Package['opendkim'],
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
  content => "127.0.0.1
localhost
${hostname}
${domain}
",
  require => File['/etc/opendkim'],
}

file { '/etc/opendkim/KeyTable':
  ensure  => file,
  content => "mail._domainkey.${domain} ${domain}:${hostname}:/etc/opendkim/keys/mail.private\n",
  require => File['/etc/opendkim'],
}

file { '/etc/opendkim/SigningTable':
  ensure  => file,
  content => "*@${domain} mail._domainkey.${domain}\n",
  require => File['/etc/opendkim'],
}

exec { 'gen-dkim-key':
  command => "opendkim-genkey -b 2048 -d ${domain} -D /etc/opendkim/keys/ -s mail -v",
  creates => '/etc/opendkim/keys/mail.private',
  path    => ['/usr/bin', '/usr/sbin'],
  require => [Package['opendkim-tools'], File['/etc/opendkim/keys']],
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
  require    => [Package['opendkim'], Exec['gen-dkim-key']],
}

# =====================================================
# POSTFIX
# =====================================================
$postfix_main = "myhostname = ${hostname}
mydomain = ${domain}
myorigin = ${domain}
inet_interfaces = all
mydestination = \$myhostname, localhost.\$mydomain, localhost, \$mydomain
mynetworks = 127.0.0.0/8 [::1]/128
home_mailbox = Maildir/
mailbox_size_limit = 0
message_size_limit = 52428800
compatibility_level = 3.6

# TLS
smtpd_tls_cert_file = ${ssl_cert}
smtpd_tls_key_file = ${ssl_key}
smtpd_use_tls = yes
smtpd_tls_auth_only = yes
smtpd_tls_security_level = may
smtp_tls_security_level = may
smtpd_tls_received_header = yes
smtpd_tls_session_cache_timeout = 3600s

# SASL via Dovecot
smtpd_sasl_type = dovecot
smtpd_sasl_path = private/auth
smtpd_sasl_auth_enable = yes

# Restrictions
smtpd_helo_required = yes
smtpd_delay_reject = yes
smtpd_client_restrictions = permit_sasl_authenticated, permit_mynetworks, reject_unknown_client_hostname
smtpd_helo_restrictions = permit_sasl_authenticated, permit_mynetworks, reject_invalid_helo_hostname, reject_non_fqdn_helo_hostname
smtpd_sender_restrictions = permit_sasl_authenticated, permit_mynetworks, reject_non_fqdn_sender, reject_unknown_sender_domain
smtpd_recipient_restrictions = permit_sasl_authenticated, permit_mynetworks, reject_unauth_destination, reject_non_fqdn_recipient
smtpd_relay_restrictions = permit_sasl_authenticated, permit_mynetworks, reject_unauth_destination

# Rate limiting
smtpd_client_message_rate_limit = 100
smtpd_client_recipient_rate_limit = 200
smtpd_client_connection_rate_limit = 30
anvil_rate_time_unit = 60s

# OpenDKIM
milter_default_action = accept
milter_protocol = 6
smtpd_milters = inet:localhost:8891
non_smtpd_milters = inet:localhost:8891

# SpamAssassin via spamc
mailbox_command = /usr/bin/spamc -e /usr/lib/dovecot/deliver
"

file { '/etc/postfix/main.cf':
  ensure  => file,
  content => $postfix_main,
  require => Package['postfix'],
  notify  => Service['postfix'],
}

# =====================================================
# DOVECOT
# =====================================================
$dovecot_conf = "protocols = imap pop3 sieve
mail_location = maildir:~/Maildir
ssl = yes
ssl_cert = </etc/ssl/certs/mail.pem
ssl_key = </etc/ssl/private/mail.key
disable_plaintext_auth = no
auth_mechanisms = plain login
!include conf.d/*.conf
"

file { '/etc/dovecot/dovecot.conf':
  ensure  => file,
  content => $dovecot_conf,
  require => Package['dovecot-core'],
  notify  => Service['dovecot'],
}

file { '/etc/dovecot/conf.d/10-auth.conf':
  ensure  => file,
  content => "disable_plaintext_auth = no\nauth_mechanisms = plain login\n!include auth-system.conf.ext\n",
  require => Package['dovecot-core'],
  notify  => Service['dovecot'],
}

$dovecot_master = "service auth {
  unix_listener /var/spool/postfix/private/auth {
    mode = 0660
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
protocol sieve {
  managesieve_max_line_length = 65536
}
plugin {
  sieve = ~/.dovecot.sieve
  sieve_dir = ~/sieve
  sieve_before = /etc/dovecot/sieve/default.sieve
}
"

file { '/etc/dovecot/conf.d/10-master.conf':
  ensure  => file,
  content => $dovecot_master,
  require => Package['dovecot-core'],
  notify  => Service['dovecot'],
}

file { '/etc/dovecot/conf.d/10-mail.conf':
  ensure  => file,
  content => "mail_location = maildir:~/Maildir\n",
  require => Package['dovecot-core'],
  notify  => Service['dovecot'],
}

# Global Sieve rule: move spam to Junk folder
file { '/etc/dovecot/sieve':
  ensure => directory,
  owner  => 'root',
  group  => 'root',
  mode   => '0755',
}

file { '/etc/dovecot/sieve/default.sieve':
  ensure  => file,
  content => 'require "fileinto";
if header :contains "X-Spam-Flag" "YES" {
  fileinto "Junk";
}
',
  require => File['/etc/dovecot/sieve'],
}

exec { 'compile-sieve':
  command => 'sievec /etc/dovecot/sieve/default.sieve',
  creates => '/etc/dovecot/sieve/default.svbin',
  path    => ['/usr/bin'],
  require => [Package['dovecot-sieve'], File['/etc/dovecot/sieve/default.sieve']],
}

# =====================================================
# SPAMASSASSIN
# =====================================================
file { '/etc/spamassassin/local.cf':
  ensure  => file,
  content => "rewrite_header Subject ***** SPAM *****
report_safe             1
required_score          5.0
use_bayes               1
bayes_auto_learn        1
bayes_auto_learn_threshold_nonspam   0.1
bayes_auto_learn_threshold_spam      12.0
skip_rbl_checks         0
use_razor2              1
use_pyzor               0
add_header all Status _YESNO_, score=_SCORE_ required=_REQD_ tests=_TESTS_ autolearn=_AUTOLEARN_
",
  require => Package['spamassassin'],
}

file { '/etc/default/spamassassin':
  ensure  => file,
  content => "ENABLED=1
SAHOME=\"/var/lib/spamassassin\"
OPTIONS=\"--create-prefs --max-children 5 --helper-home-dir=\${SAHOME}\"
PIDFILE=\"\${SAHOME}/spamd.pid\"
CRON=1
",
  require => Package['spamassassin'],
  notify  => Service['spamd'],
}

service { 'spamd':
  ensure     => running,
  enable     => true,
  hasrestart => true,
  require    => [Package['spamassassin'], File['/etc/spamassassin/local.cf'], File['/etc/default/spamassassin']],
}

# =====================================================
# FAIL2BAN
# =====================================================
file { '/etc/fail2ban/jail.local':
  ensure  => file,
  content => "[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
backend  = systemd

[sshd]
enabled  = true
port     = ssh
filter   = sshd
logpath  = /var/log/auth.log

[postfix]
enabled  = true
port     = smtp,submission
filter   = postfix
logpath  = /var/log/mail.log
maxretry = 3

[dovecot]
enabled  = true
port     = pop3,pop3s,imap,imaps,submission
filter   = dovecot
logpath  = /var/log/mail.log
maxretry = 3

[sieve]
enabled  = true
port     = 4190
filter   = dovecot
logpath  = /var/log/mail.log
maxretry = 3
",
  require => Package['fail2ban'],
  notify  => Service['fail2ban'],
}

service { 'fail2ban':
  ensure     => running,
  enable     => true,
  hasrestart => true,
  require    => [Package['fail2ban'], File['/etc/fail2ban/jail.local']],
}

# =====================================================
# SERVICES
# =====================================================
service { 'postfix':
  ensure     => running,
  enable     => true,
  hasrestart => true,
  require    => Package['postfix'],
}

service { 'dovecot':
  ensure     => running,
  enable     => true,
  hasrestart => true,
  require    => Package['dovecot-core'],
}

# =====================================================
# FIREWALL
# =====================================================
exec { 'ufw-allow-ssh':
  command => 'ufw allow 22/tcp',
  unless  => 'ufw status | grep -q "22/tcp"',
  path    => ['/usr/sbin', '/bin'],
  require => Package['ufw'],
}

exec { 'ufw-allow-mail':
  command => 'ufw allow 25/tcp && ufw allow 587/tcp && ufw allow 143/tcp && ufw allow 993/tcp && ufw allow 110/tcp && ufw allow 995/tcp && ufw allow 4190/tcp',
  unless  => 'ufw status | grep -q "25/tcp"',
  path    => ['/usr/sbin', '/bin'],
  require => Package['ufw'],
}

exec { 'ufw-enable':
  command => 'ufw --force enable',
  unless  => 'ufw status | grep -q "Status: active"',
  path    => ['/usr/sbin', '/bin'],
  require => [Exec['ufw-allow-ssh'], Exec['ufw-allow-mail']],
}
