# Puppet Mail Server — Corporate Edition

Rapid deployment of a full corporate mail server on Ubuntu 24.04 via Puppet.

Tested on Ubuntu 24.04.4 LTS ARM64 (Parallels VM on macOS). Deploy time: ~60 seconds.

## Components

| Component | Role |
|-----------|------|
| Postfix | SMTP — send and receive mail (ports 25, 587) |
| Dovecot | IMAP/POP3 — client mail access (ports 143, 993, 110, 995) |
| OpenDKIM | DKIM email signing (port 8891, internal) |
| SpamAssassin | Spam filtering with Bayes auto-learn |
| Fail2ban | Brute-force protection for SSH, SMTP, IMAP, POP3 |
| Sieve | Mail filtering rules, auto-move spam to Junk (port 4190) |
| ufw | Firewall — opens all required ports |

## Quick Start

### Option 1: Parallels VM (macOS -> Ubuntu)

```bash
# 1. Install Puppet in VM
ssh user@<VM_IP> "sudo apt update && sudo apt install -y puppet"

# 2. Copy manifest
scp mailserver.pp user@<VM_IP>:/tmp/

# 3. Apply
ssh user@<VM_IP> "sudo puppet apply /tmp/mailserver.pp"
```

### Option 2: Directly on server

```bash
sudo apt update && sudo apt install -y puppet
sudo puppet apply mailserver.pp
```

## Post-Install: DNS Records

After deploying, add these DNS records for your domain:

```
# MX record — tells other servers where to deliver mail
MX  10  mail.example.com.

# SPF — authorizes your server to send mail
TXT  @  "v=spf1 mx a ip4:<YOUR_SERVER_IP> -all"

# DKIM — get the public key from the server:
#    sudo cat /etc/opendkim/keys/mail.txt
TXT  mail._domainkey  "v=DKIM1; h=sha256; k=rsa; p=<KEY_FROM_SERVER>"

# DMARC — policy for failed SPF/DKIM
TXT  _dmarc  "v=DMARC1; p=quarantine; rua=mailto:postmaster@example.com"
```

## Verification

```bash
# Send test email
echo "Hello from mailserver" | sendmail user@localhost

# Check delivery (wait 5 sec)
ls ~/Maildir/new/
cat ~/Maildir/new/*

# All services
systemctl status postfix dovecot opendkim spamd fail2ban

# Open ports
ss -tlnp | grep -E "25|587|143|993|110|995|4190"

# DKIM public key (add to DNS)
sudo cat /etc/opendkim/keys/mail.txt

# Firewall
sudo ufw status

# Fail2ban status
sudo fail2ban-client status
sudo fail2ban-client status postfix
sudo fail2ban-client status dovecot
```

## Configuration

Before running, edit in `mailserver.pp`:

```puppet
$domain = 'example.com'  # -> your domain
```

## Ports

| Port | Protocol | Purpose |
|------|----------|---------|
| 22 | TCP | SSH |
| 25 | TCP | SMTP |
| 587 | TCP | Submission (TLS) |
| 143 | TCP | IMAP |
| 993 | TCP | IMAPS |
| 110 | TCP | POP3 |
| 995 | TCP | POP3S |
| 4190 | TCP | ManageSieve |
| 8891 | TCP | OpenDKIM (localhost only) |

## What the manifest does

1. Installs packages (postfix, dovecot, opendkim, spamassassin, fail2ban, sieve, ufw)
2. Generates a self-signed SSL certificate
3. Generates DKIM key pair (2048-bit RSA)
4. Configures OpenDKIM — signs outgoing mail, verifies incoming
5. Configures Postfix — domain, TLS, SASL, DKIM milter, rate limiting, SpamAssassin pipe
6. Configures Dovecot — IMAP/POP3, SSL, SASL, Sieve + ManageSieve
7. Configures SpamAssassin — Bayes auto-learn, RBL checks, spam header tagging
8. Configures Fail2ban — protects SSH, SMTP, IMAP/POP3, Sieve
9. Creates global Sieve rule — moves spam to Junk folder
10. Opens all ports in UFW (including SSH and ManageSieve)
