# Enterprise-Grade Puppet Mail Infrastructure

A production-ready, highly secure, and modern mail server stack managed entirely by a single Puppet manifest. This project implements a full corporate mail ecosystem that goes beyond standard "howto" guides, reaching the architectural quality of professional solutions like iRedMail or ISPConfig.

## 🏗 Architecture & Stack

- **MTA (Mail Transfer Agent):** Postfix with MySQL backend
- **MDA (Mail Delivery Agent):** Dovecot with LMTP support
- **Database:** MariaDB (Virtual users, domains, aliases)
- **Webmail:** Roundcube (PHP 8.3+) with 2FA support
- **Administration:** PostfixAdmin
- **Security Stack:** SpamAssassin (Bayes), OpenDKIM, OpenDMARC, Policyd-SPF, Postgrey, Postscreen, Fail2ban
- **Modern Web/Mail Standards:** MTA-STS, TLS-RPT, Autodiscover/Autoconfig (iOS/Outlook/Thunderbird)

## 🔐 Key Security Features

- **Hardened SMTP:** Postscreen with DNSBL integration, Greylisting, and deep protocol checks.
- **Full Auth Encryption:** SHA512-CRYPT hashed passwords.
- **Two-Factor Authentication:** GAuthenticator support for Roundcube.
- **Header Privacy:** Automatic stripping of internal IP addresses and MUA details from outgoing headers.
- **Fail2ban Integration:** Pre-configured jails for Postfix, Dovecot, and Roundcube (24h ban for SASL failures).
- **Inbound Filtering:** Multi-stage spam detection with SpamAssassin + Sieve auto-junk filing (GTUBE validated).

## 🚀 Modern Connectivity & Reliability

- **SSL/TLS 1.2+:** Forced encryption on all ports with DH parameters and HSTS.
- **OCSP Stapling:** Enabled for faster SSL validation.
- **MTA-STS & TLS-RPT:** Enhanced protection against downgrade attacks and visibility into delivery issues.
- **Client Auto-Config:** Full support for `autoconfig.xml` and `autodiscover.xml`.
- **Quotas:** Real-time quota enforcement with `quota-status` notifications.
- **Reliability:** Built-in healthchecks, automated backups with retention, and comprehensive log rotation.

## 🛠 Getting Started

### 1. Requirements
- Ubuntu 24.04 LTS (ARM64/x64)
- Puppet Agent installed
- A valid FQDN (e.g., `mail.example.com`)

### 2. Configuration
Edit the top variables in `manifests/mailserver_full.pp`:
```puppet
$domain     = 'yourdomain.com'
$db_pass    = 'choose_a_strong_password'
$admin_pass = 'choose_admin_password'
```

### 3. Deployment
```bash
sudo puppet apply manifests/mailserver_full.pp
```

## 🔑 Access & Credentials

| Service | URL Path | Login |
|---------|----------|---------------|
| **Roundcube Webmail** | `https://mail.example.com/mail/` | `admin@example.com` |
| **PostfixAdmin** | `https://mail.example.com/admin/` | `admin@example.com` |

**Default Passwords (as set in manifest):**
- **Admin Password:** `adminpass123`
- **Mail User DB:** `maildbpass123`
- **Roundcube DB:** `RcMail2024!Db`

> [!TIP]
> On the current VM, you can access these via `https://10.211.55.11/mail/` and `https://10.211.55.11/admin/`. Accept the self-signed certificate warning to proceed.

## ✅ Production Readiness Checklist

Before moving this stack to production, ensure you complete the following steps:

1. **Secrets:** Change all default passwords in the manifest variables.
2. **Reverse DNS (PTR):** Configure a PTR record for your IP to match your mail hostname (e.g., `IP -> PTR -> mail.yourdomain.com`). This is critical for Gmail/Outlook delivery.
3. **SSL Certificates:** While the manifest generates self-signed certs, replace them with Let's Encrypt for production. A helper script is provided at `/usr/local/bin/get-ssl-cert.sh`.
4. **DNS Records:** Follow the template generated in `/root/dns-records.txt` to set up SPF, DKIM, DMARC, CAA, and BIMI records.
5. **Validation:** Test your final score via [mail-tester.com](https://www.mail-tester.com). Aim for 10/10.

## 🧪 Testing

The project includes a comprehensive Python-based stress test suite (`tests/stress_test.py`) that verifies:
- Port connectivity and TLS versions.
- Concurrent IMAP/SMTP sessions.
- Spam detection (GTUBE) and Sieve movement.
- Large attachment handling (up to 20MB+).
- Rate limiting and Fail2ban triggers.

---
*Developed as a high-hardened DevOps mail stack for portfolio and enterprise-grade infrastructure projects.*
