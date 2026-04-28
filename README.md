# Puppet Mail Server — Full Corporate Edition

Rapid deployment of a full corporate mail server on Ubuntu 24.04 via Puppet.
Two manifests: simple (system users) and full corporate (MySQL virtual users).

Tested on Ubuntu 24.04.4 LTS ARM64 (Parallels VM on macOS).

## Editions

| Edition | File | Users | Extra |
|---------|------|-------|-------|
| **Simple** | `mailserver.pp` | System (Linux PAM) | Postfix + Dovecot + OpenDKIM + SpamAssassin + Fail2ban + Sieve |
| **Corporate** | `mailserver_full.pp` | MySQL virtual users | + Roundcube + PostfixAdmin + Quotas + Vacation + Autodiscover + Backup |

## Corporate Edition — Disk Footprint

| Item | Size |
|------|------|
| PuppetCode/ (manifest + tests + docs) | 35 KB |
| Postfix + MySQL maps | 4 MB |
| Dovecot (IMAP/POP3/LMTP/Sieve/MySQL) | 16 MB |
| OpenDKIM | 264 KB |
| SpamAssassin + rules | 3.4 MB |
| Fail2ban | 3.7 MB |
| MariaDB | 120 MB |
| Nginx + PHP 8.3 FPM | 18 MB |
| Roundcube | 22 MB |
| PostfixAdmin | 6 MB |
| Certbot | 12 MB |
| **Total** | **~206 MB** |

## Components

| Component | Role |
|-----------|------|
| Postfix | SMTP — virtual users via MySQL, DKIM milter, SpamAssassin pipe, rate limiting |
| Dovecot | IMAP/POP3/LMTP — MySQL auth, Sieve, quotas, auto-create folders |
| MariaDB | Virtual users, aliases, domains, Roundcube DB |
| OpenDKIM | DKIM email signing (port 8891, internal) |
| SpamAssassin | Spam filtering with Bayes, Razor, Pyzor, DNSBL, URIBL |
| Fail2ban | Brute-force protection for SSH, SMTP, IMAP/POP3, Sieve |
| Roundcube | Webmail at `/mail` — Sieve filters, vacation, spam buttons |
| PostfixAdmin | Admin panel at `/admin` — domains, users, aliases, quotas |
| Nginx + PHP 8.3 | Web server for Roundcube, PostfixAdmin, autodiscover |
| Sieve | Mail filtering, spam-to-Junk, vacation auto-responder (port 4190) |
| Certbot | Let's Encrypt SSL (manual step after DNS setup) |
| ufw | Firewall — opens all required ports |

## Quick Start

### Option 1: Simple Edition (system users)

```bash
ssh user@<VM_IP> "sudo apt update && sudo apt install -y puppet"
scp mailserver.pp user@<VM_IP>:/tmp/
ssh user@<VM_IP> "sudo puppet apply /tmp/mailserver.pp"
```

### Option 2: Corporate Edition (MySQL virtual users)

```bash
ssh user@<VM_IP> "sudo apt update && sudo apt install -y puppet"
scp mailserver_full.pp user@<VM_IP>:/tmp/
ssh user@<VM_IP> "sudo puppet apply /tmp/mailserver_full.pp"
```

Deploy time: ~140 seconds (corporate), ~60 seconds (simple).

## Post-Install: DNS Records

```
# MX record
MX  10  mail.example.com.

# SPF
TXT  @  "v=spf1 mx a ip4:<YOUR_SERVER_IP> -all"

# DKIM — get the public key:
#    sudo cat /etc/opendkim/keys/mail.txt
TXT  mail._domainkey  "v=DKIM1; h=sha256; k=rsa; p=<KEY_FROM_SERVER>"

# DMARC
TXT  _dmarc  "v=DMARC1; p=quarantine; rua=mailto:postmaster@example.com"

# Autoconfig (Thunderbird) — served automatically at:
#    http://mail.example.com/.well-known/autoconfig/mail/config-v1.1.xml

# Autodiscover (Outlook) — served automatically at:
#    http://mail.example.com/autodiscover/autodiscover.xml
```

## Post-Install: Let's Encrypt SSL

```bash
# After DNS points to your server:
sudo certbot --nginx -d mail.example.com -d example.com

# Auto-renewal:
sudo systemctl enable certbot.timer
sudo systemctl start certbot.timer
```

## Post-Install: PostfixAdmin

1. Open `http://<SERVER_IP>/admin/`
2. Create setup password → get hash
3. Add hash to `/etc/postfixadmin/config.local.php`
4. Create admin account
5. Add domains, mailboxes, aliases via web UI

## Default Accounts (Corporate Edition)

| Account | Password | Purpose |
|---------|----------|---------|
| admin@example.com | adminpass123 | Default mailbox (1 GB quota) |
| postmaster@example.com | adminpass123 | Postmaster mailbox (1 GB quota) |
| info@example.com | → admin@example.com | Alias |
| support@example.com | → admin@example.com | Alias |
| MariaDB mailuser | maildbpass123 | Database access |

**Change all passwords before production use.**

## Verification

```bash
# All services
systemctl status postfix dovecot opendkim spamd fail2ban mariadb nginx php8.3-fpm

# Open ports
ss -tlnp | grep -E "25|587|143|993|110|995|4190|80|443|3306|8891"

# Virtual user auth test
sudo doveadm auth test admin@example.com

# DKIM public key (add to DNS)
sudo cat /etc/opendkim/keys/mail.txt

# Web interfaces
curl -s -o /dev/null -w '%{http_code}' http://<SERVER_IP>/mail/
curl -s -o /dev/null -w '%{http_code}' http://<SERVER_IP>/admin/

# Send test email
echo "Hello" | sendmail admin@example.com

# Check delivery
sudo ls /var/mail/vmail/example.com/admin/Maildir/new/

# Database
sudo mysql -umailuser -pmaildbpass123 mailserver -e 'SHOW TABLES;'

# Firewall
sudo ufw status

# Fail2ban
sudo fail2ban-client status
```

## Configuration

Before running, edit in the manifest:

```puppet
$domain     = 'example.com'    # -> your domain
$db_pass    = 'maildbpass123'  # -> strong DB password
$admin_pass = 'adminpass123'   # -> strong admin password
```

## Ports

| Port | Protocol | Purpose |
|------|----------|---------|
| 22 | TCP | SSH |
| 25 | TCP | SMTP |
| 587 | TCP | Submission (STARTTLS) |
| 80 | TCP | HTTP (Roundcube, PostfixAdmin, ACME) |
| 443 | TCP | HTTPS (after Let's Encrypt) |
| 143 | TCP | IMAP |
| 993 | TCP | IMAPS |
| 110 | TCP | POP3 |
| 995 | TCP | POP3S |
| 4190 | TCP | ManageSieve |
| 3306 | TCP | MariaDB (localhost only) |
| 8891 | TCP | OpenDKIM (localhost only) |

## What the Corporate Manifest Does

1. Installs packages (postfix-mysql, dovecot-mysql, mariadb, nginx, php, roundcube, postfixadmin, certbot)
2. Generates self-signed SSL certificate (replace with Let's Encrypt)
3. Creates MariaDB database with virtual_domains, virtual_users, virtual_aliases tables
4. Seeds default domain, admin user, postmaster, and aliases
5. Creates vmail user (uid/gid 5000) with /var/mail/vmail storage
6. Generates DKIM key pair (2048-bit RSA)
7. Configures OpenDKIM — signs outgoing, verifies incoming
8. Configures Postfix — MySQL virtual users, LMTP delivery, DKIM milter, SpamAssassin content filter
9. Configures Dovecot — MySQL auth, LMTP, Sieve + vacation, quotas (1 GB default), auto-create folders
10. Configures SpamAssassin — Bayes, Razor, Pyzor, DNSBL, URIBL, custom rules
11. Configures Fail2ban — SSH, SMTP, IMAP/POP3, Sieve
12. Configures Nginx + PHP 8.3 FPM — Roundcube at /mail, PostfixAdmin at /admin
13. Deploys autodiscover (Outlook) and autoconfig (Thunderbird) XML
14. Configures Roundcube — MySQL, IMAP/SMTP, Sieve, vacation plugin
15. Configures PostfixAdmin — MySQL, quotas, vacation, aliases
16. Sets up daily backup cron (mysqldump + rsync, 30-day retention)
17. Opens all ports in UFW

## Load Testing

A Python test suite is included (`stress_test.py`). Runs from macOS host against the VM.

```bash
# For simple edition — update VM_IP in script first
unset PYTHONHOME && unset PYTHONPATH && /usr/bin/python3 stress_test.py
```

### Test Suite (Simple Edition)

| # | Test | Description |
|---|------|-------------|
| 1 | Connectivity | TCP check all 7 ports |
| 2 | SMTP Single | Send 1 email, verify delivery |
| 3 | SMTP Batch | Send 100 emails, measure throughput |
| 4 | SMTP Concurrent | Send 200 emails via 10 threads |
| 5 | IMAP Login | Login, select INBOX, count messages |
| 6 | IMAP Concurrent | 20 simultaneous IMAP sessions |
| 7 | POP3 Login | Login, stat messages and size |
| 8 | Spam Detection | Send clean + spam, verify spam → Junk |
| 9 | Fail2ban | 8 wrong password attempts, verify ban |
| 10 | Sustained Load | 15 seconds at 5 msg/sec |

### Benchmarks (Simple Edition — Ubuntu 24.04 ARM64, 2 CPU, 2GB RAM)

| Metric | Result |
|--------|--------|
| SMTP batch (100 msg) | **15.1 msg/sec** |
| SMTP concurrent (200 msg, 10 threads) | **140.7 msg/sec** |
| IMAP concurrent (20 sessions) | **20/20 in 0.1s** |
| Spam detection (external spam) | **Score 16.7, auto-move to Junk** |
| Clean mail (legitimate) | **Score 1.4, delivered to Inbox** |
| Fail2ban trigger | **Ban after 2 bad attempts** |
| Total test time | **~43 seconds** |

## Backup

Daily backup runs at 02:17 via cron:
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

## File Structure

```
PuppetCode/
├── mailserver.pp        — simple edition (system users, ~25 MB)
├── mailserver_full.pp   — corporate edition (MySQL virtual users, ~206 MB)
├── stress_test.py       — load test suite (run from macOS host)
└── README.md            — documentation
```
