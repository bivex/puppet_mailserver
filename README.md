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
| Postgrey | Greylisting on port 10023 |
| Fail2ban | 5 jails: sshd, postfix, postfix-sasl (24h ban), dovecot, sieve |
| Roundcube | Webmail at `/mail` — Sieve filters, spam buttons |
| PostfixAdmin | Admin panel at `/admin` — domains, users, aliases, quotas |
| Nginx + PHP 8.3 | HTTPS (TLS 1.2+), Roundcube, PostfixAdmin, autodiscover/autoconfig |
| Certbot | Let's Encrypt SSL (manual step after DNS) |
| UFW | Firewall — all mail and web ports open |

## Ports

| Port | Protocol | Purpose |
|------|----------|---------|
| 22 | TCP | SSH |
| 25 | TCP | SMTP — incoming mail |
| 587 | TCP | Submission — client sending (STARTTLS + SASL required) |
| 465 | TCP | SMTPS — client sending (TLS wrapper mode) |
| 80 | TCP | HTTP → redirect to HTTPS, ACME challenge |
| 443 | TCP | HTTPS — all web interfaces |
| 143 | TCP | IMAP |
| 993 | TCP | IMAPS (SSL) |
| 110 | TCP | POP3 |
| 995 | TCP | POP3S (SSL) |
| 4190 | TCP | ManageSieve |
| 8891 | TCP | OpenDKIM (localhost only) |
| 10023 | TCP | Postgrey (localhost only) |

## Web Interfaces

| Service | URL |
|---------|-----|
| **PostfixAdmin** | [https://mail.example.com/admin/](https://mail.example.com/admin/) |
| **Roundcube Webmail** | [https://mail.example.com/mail/](https://mail.example.com/mail/) |
| Autoconfig (Thunderbird) | [https://mail.example.com/.well-known/autoconfig/mail/config-v1.1.xml](https://mail.example.com/.well-known/autoconfig/mail/config-v1.1.xml) |
| Autodiscover (Outlook) | [https://mail.example.com/autodiscover/autodiscover.xml](https://mail.example.com/autodiscover/autodiscover.xml) |

### Login Credentials

#### PostfixAdmin
```
URL:      https://mail.example.com/admin/login.php
Username: admin@example.com
Password: adminpass123
```

#### Roundcube Webmail
```
URL:      https://mail.example.com/mail/
Username: admin@example.com
Password: adminpass123
```

## Corporate Features

- **Header privacy** — strip User-Agent, X-Mailer, X-Originating-IP, X-PHP-Originating-Script
- **Rate limiting** — 100 msgs/min, 200 rcpts/min, 30 connections/min
- **Postscreen** — DNSBL checks (SpamHaus, SORBS, SpamEatingMonkey), rejects bots before queue
- **Quota enforcement** — Dovecot quota-status policy service, 1 GB default, rejects on overflow
- **Vacation/autoreply** — Dovecot Sieve vacation, managed via Roundcube managesieve plugin UI
- **Sieve** — auto-move spam to Junk, custom user filters via Roundcube
- **Postgrey** — greylisting, first message from new senders is deferred for 5 min
- **Fail2ban** — postfix-sasl jail with 24h ban for brute-force attempts
- **HTTPS** — TLS 1.2+, modern ciphers, self-signed (Let's Encrypt ready)
- **Submission 587** — mandatory TLS + SASL auth for client mail submission
- **SMTPS 465** — TLS wrapper mode for clients without STARTTLS
- **SpamAssassin** — Razor, Pyzor, Bayes, custom rules (viagra, suspicious TLD)
- **Backup** — daily mysqldump + rsync Maildir, 30-day retention
- **Monitoring** — healthcheck cron every 10 min, log at /var/log/mail-healthcheck.log
- **Logrotate** — /var/log/mail.log, weekly, 12-week rotation
- **DNS template** — /root/dns-records.txt with all required records

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

## Optional Enhancements (not included)

- **ClamAV** — antivirus (excluded — too heavy for ARM64 VM)
- **SOGo / Nextcloud** — calendar, contacts, groupware
- **Mailman** — mailing lists
- **Prometheus + Grafana** — monitoring dashboards

## File Structure

```
PuppetCode/
├── mailserver_full.pp        — corporate edition manifest
├── postfixadmin_schema.sql   — PostfixAdmin 3.3 DB schema
├── postfixadmin.sql          — placeholder (points to schema)
├── stress_test.py            — load test suite
└── README.md                 — this file
```
