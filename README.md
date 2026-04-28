# Puppet Mail Server — Full Corporate Edition

Rapid deployment of a full corporate mail server on Ubuntu 24.04 via Puppet.

Tested on Ubuntu 24.04.4 LTS ARM64 (Parallels VM on macOS).

## Quick Start

```bash
# Inside VM
sudo puppet apply mailserver_full.pp
```

Deploy time: ~140 seconds.

## Components

| Component | Role |
|-----------|------|
| Postfix | SMTP — virtual users via MySQL, DKIM milter, SpamAssassin pipe, rate limiting, postscreen DNSBL |
| Dovecot | IMAP/POP3/LMTP — MySQL auth, Sieve, quotas, auto-create folders |
| MariaDB | Virtual users, aliases, domains, Roundcube DB |
| OpenDKIM | DKIM email signing (port 8891, RSA 2048, relaxed/simple) |
| SpamAssassin | Spam filtering with Bayes, Razor, Pyzor, DNSBL, URIBL, custom rules |
| Postgrey | Greylisting на порту 10023 |
| Fail2ban | 5 jail'ов: sshd, postfix, postfix-sasl (24h ban), dovecot, sieve |
| Roundcube | Webmail at `/mail` — Sieve filters, spam buttons |
| PostfixAdmin | Admin panel at `/admin` — domains, users, aliases, quotas |
| Nginx + PHP 8.3 | HTTPS (TLS 1.2+), Roundcube, PostfixAdmin, autodiscover/autoconfig |
| Certbot | Let's Encrypt SSL (ручной шаг после DNS) |
| UFW | Firewall — все почтовые и веб-порты открыты |

## Ports

| Port | Protocol | Purpose |
|------|----------|---------|
| 22 | TCP | SSH |
| 25 | TCP | SMTP — приём входящей почты |
| 587 | TCP | Submission — отправка клиентами (STARTTLS + SASL обязателен) |
| 465 | TCP | SMTPS — отправка (TLS wrapper mode) |
| 80 | TCP | HTTP → редирект на HTTPS, ACME challenge |
| 443 | TCP | HTTPS — все веб-интерфейсы |
| 143 | TCP | IMAP |
| 993 | TCP | IMAPS (SSL) |
| 110 | TCP | POP3 |
| 995 | TCP | POP3S (SSL) |
| 4190 | TCP | ManageSieve |
| 8891 | TCP | OpenDKIM (localhost only) |
| 10023 | TCP | Postgrey (localhost only) |

## Web Interfaces

| URL | Description |
|-----|-------------|
| `https://mail.example.com/admin/` | PostfixAdmin — управление доменами, ящиками, алиасами |
| `https://mail.example.com/mail/` | Roundcube — веб-клиент |
| `https://mail.example.com/.well-known/autoconfig/mail/config-v1.1.xml` | Autoconfig (Thunderbird) |
| `https://mail.example.com/autodiscover/autodiscover.xml` | Autodiscover (Outlook) |

## Corporate Features

- **Header privacy** — strip User-Agent, X-Mailer, X-Originating-IP, X-PHP-Originating-Script
- **Rate limiting** — 100 msgs/min, 200 rcpts/min, 30 connections/min
- **Postscreen** — DNSBL-проверки (SpamHaus, SORBS, SpamEatingMonkey), отсекает ботов до очереди
- **Quota enforcement** — Dovecot quota-status policy service, 1 GB default, rejects при переполнении
- **Vacation/autoreply** — transport map на autoreply.example.com
- **Sieve** — авто-перемещение спама в Junk, пользовательские фильтры через Roundcube
- **Postgrey** — greylisting, первые письма от новых отправителей отклоняются на 5 мин
- **Fail2ban** — postfix-sasl jail с 24h баном за брутфорс
- **HTTPS** — TLS 1.2+, современные шифры, self-signed (Let's Encrypt ready)
- **Submission 587** — обязательный TLS + SASL auth для отправки почты клиентами
- **SMTPS 465** — TLS wrapper mode для клиентов без STARTTLS
- **SpamAssassin** — Razor, Pyzor, Bayes, кастомные правила (viagra, suspicious TLD)
- **Backup** — ежедневный mysqldump + rsync Maildir, 30 дней хранения
- **Monitoring** — healthcheck cron каждые 10 мин, лог в /var/log/mail-healthcheck.log
- **Logrotate** — /var/log/mail.log, weekly, 12 недель ротация
- **DNS template** — /root/dns-records.txt со всеми нужными записями

## Default Accounts

| Account | Password | Purpose |
|---------|----------|---------|
| admin@example.com | adminpass123 | Admin mailbox (1 GB quota) |
| postmaster@example.com | adminpass123 | Postmaster mailbox (1 GB quota) |
| info@example.com | → admin@example.com | Alias |
| support@example.com | → admin@example.com | Alias |
| abuse@example.com | → admin@example.com | Alias |
| hostmaster@example.com | → admin@example.com | Alias |
| webmaster@example.com | → admin@example.com | Alias |
| MariaDB mailuser | maildbpass123 | Database access |

**Change all passwords before production use.**

## Configuration

Before running, edit in the manifest:

```puppet
$domain     = 'example.com'    # -> your domain
$hostname   = "mail.${domain}" # -> your mail hostname
$db_pass    = 'maildbpass123'  # -> strong DB password
$admin_pass = 'adminpass123'   # -> strong admin password
```

## Post-Install: DNS Records

DNS records template is at `/root/dns-records.txt` on the VM. Add these to your DNS provider:

```
# MX
MX  10  mail.example.com.

# A record
A   mail.example.com.  <YOUR_SERVER_IP>

# SPF
TXT  example.com.  "v=spf1 mx a ip4:<YOUR_SERVER_IP> ~all"

# DKIM — get the real key:
#   sudo cat /etc/opendkim/keys/mail.txt
TXT  mail._domainkey.example.com.  "v=DKIM1; h=sha256; k=rsa; p=<KEY>"

# DMARC
TXT  _dmarc.example.com.  "v=DMARC1; p=quarantine; rua=mailto:postmaster@example.com"

# PTR (reverse DNS) — set at hosting provider
PTR  <YOUR_SERVER_IP>  ->  mail.example.com.

# Autodiscover SRV (Outlook)
SRV  _autodiscover._tcp.example.com.  0 443 autodiscover.example.com.
```

## Post-Install: Let's Encrypt SSL

```bash
# After DNS points to your server:
sudo certbot --nginx -d mail.example.com -d example.com

# Auto-renewal:
sudo systemctl enable certbot.timer
sudo systemctl start certbot.timer
```

## Verification

```bash
# All services
for svc in postfix dovecot nginx opendkim mariadb php8.3-fpm fail2ban postgrey spamd; do
  printf "%-15s %s\n" $svc $(systemctl is-active $svc)
done

# Open ports
ss -tlnp | grep -E ":(25|587|465|143|993|110|995|443|80|4190|8891|10023) "

# Virtual user auth test
sudo doveadm auth test admin@example.com

# DKIM public key (add to DNS)
sudo cat /etc/opendkim/keys/mail.txt

# Web interfaces
curl -sk -o /dev/null -w '%{http_code}' https://localhost/admin/
curl -sk -o /dev/null -w '%{http_code}' https://localhost/mail/

# Send test email
echo "Test" | sendmail -f admin@example.com postmaster@example.com

# Check delivery
sudo ls /var/mail/vmail/example.com/admin/Maildir/new/

# Database
sudo mysql -umailuser -pmaildbpass123 mailserver -e 'SHOW TABLES;'

# Firewall
sudo ufw status

# Fail2ban jails
sudo fail2ban-client status
```

## Backup

Daily backup at 02:17 via cron:
- MySQL dump (compressed) → `/var/backups/mail/mailserver-YYYYMMDD.sql.gz`
- Maildir incremental rsync → `/var/backups/mail/vmail-latest/`
- 30-day retention for SQL dumps

```bash
# Manual backup
sudo /usr/local/bin/backup-mail.sh

# Restore database
gunzip < /var/backups/mail/mailserver-20260428.sql.gz | mysql -umailuser -pmaildbpass123 mailserver

# Restore maildir
rsync -a /var/backups/mail/vmail-latest/ /var/mail/vmail/
```

## Known Minor Issues

- **LMTP TLS warning**: `opportunistic TLS not appropriate for unix-domain` — косметическое, можно убрать `lmtp_tls_security_level = may` из main.cf
- **Postfix chroot SSL warning**: `/var/spool/postfix/etc/ssl/certs/mail.pem differs` — не влияет на работу
- **Vacation autoreply**: transport map настроен, vacation-скрипт от PostfixAdmin требует проверки end-to-end
- **Roundcube vacation plugin**: может не входить в стандартную поставку Ubuntu

## Optional Enhancements (not included)

- **ClamAV** — антивирус (исключён — тяжёлый для ARM64 VM)
- **SOGo / Nextcloud** — календарь, контакты, групповая работа
- **Mailman** — списки рассылки (mailing lists)
- **Prometheus + Grafana** — мониторинг и дашборды

## File Structure

```
PuppetCode/
├── mailserver_full.pp        — corporate edition manifest
├── postfixadmin_schema.sql   — PostfixAdmin 3.3 DB schema
├── postfixadmin.sql          — placeholder (points to schema)
├── stress_test.py            — load test suite
└── README.md                 — this file
```
