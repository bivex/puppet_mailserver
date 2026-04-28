# Puppet Mail Server Manifest
# Deploys: Postfix (SMTP) + Dovecot (IMAP/POP3) + Maildir
# Usage: sudo puppet apply site.pp

# --- Variables ---
$domain = 'example.com'
$mail_packages = ['postfix', 'dovecot-core', 'dovecot-imapd', 'dovecot-pop3d', 'mailutils']
$ssl_cert = '/etc/ssl/certs/mail.pem'
$ssl_key  = '/etc/ssl/private/mail.key'

# --- Install packages ---
package { $mail_packages:
  ensure => installed,
}

# --- Postfix configuration ---
file { '/etc/postfix/main.cf':
  ensure  => file,
  content => epp('postfix_main.cf.epp', {
    domain   => $domain,
    ssl_cert => $ssl_cert,
    ssl_key  => $ssl_key,
  }),
  require => Package['postfix'],
  notify  => Service['postfix'],
}

file { '/etc/postfix/master.cf':
  ensure  => file,
  source  => 'puppet:///modules/postfix/master.cf',
  content => @(MASTERCF)
    # Postfix master process configuration
    smtp      inet  n       -       y       -       -       smtpd
    submission inet  n       -       y       -       -       smtpd
      -o syslog_name=postfix/submission
      -o smtpd_tls_security_level=encrypt
      -o smtpd_sasl_auth_enable=yes
      -o smtpd_tls_auth_only=yes
      -o smtpd_reject_unlisted_recipient=no
      -o smtpd_recipient_restrictions=permit_sasl_authenticated,reject
      -o milter_macro_daemon_name=ORIGINATING
    smtps     inet  n       -       y       -       -       smtpd
      -o syslog_name=postfix/smtps
      -o smtpd_tls_wrappermode=yes
      -o smtpd_sasl_auth_enable=yes
      -o smtpd_recipient_restrictions=permit_sasl_authenticated,reject
    587       inet  n       -       -       -       -       smtpd
  | MASTERCF,
  require => Package['postfix'],
  notify  => Service['postfix'],
}

# --- Dovecot configuration ---
file { '/etc/dovecot/dovecot.conf':
  ensure  => file,
  content => @(DOVECOT_CONF)
    protocols = imap pop3
    ssl = required
    ssl_cert = <${ssl_cert}>
    ssl_key = <${ssl_key}>
    mail_location = maildir:~/Maildir
    disable_plaintext_auth = no
    auth_mechanisms = plain login
    passdb {
      driver = pam
    }
    userdb {
      driver = passwd
    }
  | DOVECOT_CONF,
  require => Package['dovecot-core'],
  notify  => Service['dovecot'],
}

file { '/etc/dovecot/conf.d/10-mail.conf':
  ensure  => file,
  content => "mail_location = maildir:~/Maildir\n",
  require => Package['dovecot-core'],
  notify  => Service['dovecot'],
}

# --- Self-signed SSL cert (for quick start) ---
exec { 'generate-mail-ssl-cert':
  command => "openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout ${ssl_key} -out ${ssl_cert} \
    -subj '/CN=mail.${domain}'",
  creates => $ssl_cert,
  path    => ['/usr/bin', '/usr/sbin'],
  require => Package['postfix'],
}

file { $ssl_key:
  mode    => '0600',
  owner   => 'root',
  group   => 'root',
  require => Exec['generate-mail-ssl-cert'],
}

# --- Services ---
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

# --- Open firewall ports (ufw) ---
package { 'ufw':
  ensure => installed,
}

exec { 'allow-smtp':
  command => 'ufw allow 25/tcp',
  unless  => 'ufw status verbose | grep -q "25/tcp"',
  path    => ['/usr/sbin', '/bin'],
  require => Package['ufw'],
}

exec { 'allow-smtps':
  command => 'ufw allow 465/tcp',
  unless  => 'ufw status verbose | grep -q "465/tcp"',
  path    => ['/usr/sbin', '/bin'],
  require => Package['ufw'],
}

exec { 'allow-submission':
  command => 'ufw allow 587/tcp',
  unless  => 'ufw status verbose | grep -q "587/tcp"',
  path    => ['/usr/sbin', '/bin'],
  require => Package['ufw'],
}

exec { 'allow-imap':
  command => 'ufw allow 143/tcp',
  unless  => 'ufw status verbose | grep -q "143/tcp"',
  path    => ['/usr/sbin', '/bin'],
  require => Package['ufw'],
}

exec { 'allow-imaps':
  command => 'ufw allow 993/tcp',
  unless  => 'ufw status verbose | grep -q "993/tcp"',
  path    => ['/usr/sbin', '/bin'],
  require => Package['ufw'],
}

exec { 'allow-pop3':
  command => 'ufw allow 110/tcp',
  unless  => 'ufw status verbose | grep -q "110/tcp"',
  path    => ['/usr/sbin', '/bin'],
  require => Package['ufw'],
}

exec { 'allow-pop3s':
  command => 'ufw allow 995/tcp',
  unless  => 'ufw status verbose | grep -q "995/tcp"',
  path    => ['/usr/sbin', '/bin'],
  require => Package['ufw'],
}

# --- Enable ufw if not active ---
exec { 'enable-ufw':
  command => 'ufw --force enable',
  unless  => 'ufw status | grep -q "Status: active"',
  path    => ['/usr/sbin', '/bin'],
  require => Package['ufw'],
}
