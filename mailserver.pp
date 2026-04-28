# Mail Server - Fast Deploy (tested on Ubuntu 24.04 ARM64)
# Run: sudo puppet apply mailserver.pp

$domain   = 'example.com'
$ssl_cert = '/etc/ssl/certs/mail.pem'
$ssl_key  = '/etc/ssl/private/mail.key'

# ---------- Packages ----------
$pkgs = ['postfix', 'dovecot-core', 'dovecot-imapd', 'dovecot-pop3d', 'mailutils', 'ufw']
package { $pkgs: ensure => installed }

# ---------- SSL self-signed cert ----------
exec { 'gen-mail-cert':
  command => "openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout ${ssl_key} -out ${ssl_cert} -subj '/CN=mail.${domain}'",
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

# ---------- Postfix main.cf ----------
$postfix_main = "myhostname = mail.${domain}
mydomain = ${domain}
myorigin = ${domain}
inet_interfaces = all
mydestination = \$myhostname, localhost.\$mydomain, localhost, \$mydomain
mynetworks = 127.0.0.0/8 [::1]/128
home_mailbox = Maildir/
mailbox_size_limit = 0
message_size_limit = 52428800
compatibility_level = 3.6
smtpd_tls_cert_file = ${ssl_cert}
smtpd_tls_key_file = ${ssl_key}
smtpd_use_tls = yes
smtpd_tls_auth_only = yes
smtpd_sasl_type = dovecot
smtpd_sasl_path = private/auth
smtpd_sasl_auth_enable = yes
smtpd_recipient_restrictions = permit_sasl_authenticated, permit_mynetworks, reject_unauth_destination
smtpd_relay_restrictions = permit_sasl_authenticated, permit_mynetworks, reject_unauth_destination
"

file { '/etc/postfix/main.cf':
  ensure  => file,
  content => $postfix_main,
  require => Package['postfix'],
  notify  => Service['postfix'],
}

# ---------- Dovecot main ----------
# Note: ssl_cert/ssl_key use < prefix (no closing >) - Dovecot syntax
$dovecot_conf = "protocols = imap pop3
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

# Dovecot SASL socket for Postfix + listeners
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

# ---------- Services ----------
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

# ---------- Firewall ----------
exec { 'ufw-allow-ssh':
  command => 'ufw allow 22/tcp',
  unless  => 'ufw status | grep -q "22/tcp"',
  path    => ['/usr/sbin', '/bin'],
  require => Package['ufw'],
}

exec { 'ufw-allow-mail':
  command => 'ufw allow 25/tcp && ufw allow 587/tcp && ufw allow 143/tcp && ufw allow 993/tcp && ufw allow 110/tcp && ufw allow 995/tcp',
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
