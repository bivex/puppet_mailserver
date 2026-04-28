# Puppet Mail Server

Rapid deployment of a mail server (Postfix + Dovecot) on Ubuntu 24.04 via Puppet.

Tested on Ubuntu 24.04.4 LTS ARM64 (Parallels VM on macOS). Deploy time: ~28 seconds.

## Components

| Component | Role |
|-----------|------|
| Postfix   | SMTP — send and receive mail (ports 25, 587) |
| Dovecot   | IMAP/POP3 — client mail access (ports 143, 993, 110, 995) |
| mailutils | Command-line mail utilities |
| ufw       | Firewall — opens ports 22, 25, 587, 143, 993, 110, 995 |

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

## Verification

```bash
# Send test email
echo "Hello from mailserver" | sendmail user@localhost

# Check delivery (wait 5 sec)
ls ~/Maildir/new/
cat ~/Maildir/new/*

# Service status
systemctl status postfix dovecot

# Open ports
ss -tlnp | grep -E "25|587|143|993|110|995"

# Firewall
sudo ufw status
```

## Configuration

Before running, edit in `mailserver.pp`:

```puppet
$domain = 'example.com'  # -> your domain
```

## Ports

| Port | Protocol | Purpose |
|------|----------|---------|
| 22   | TCP      | SSH |
| 25   | TCP      | SMTP |
| 587  | TCP      | Submission (TLS) |
| 143  | TCP      | IMAP |
| 993  | TCP      | IMAPS |
| 110  | TCP      | POP3 |
| 995  | TCP      | POP3S |

## File Structure

```
PuppetCode/
├── mailserver.pp   — main manifest (single file, all-in-one)
└── README.md       — documentation
```

## What the manifest does

1. Installs packages (postfix, dovecot, mailutils, ufw)
2. Generates a self-signed SSL certificate
3. Configures Postfix (main.cf) — domain, TLS, SASL via Dovecot, Maildir
4. Configures Dovecot — IMAP/POP3, SSL, SASL socket for Postfix
5. Starts and enables services
6. Opens ports in UFW (including SSH)
