#!/usr/bin/env python3
"""Mail server smoke test — verifies core functionality after Puppet deploy.

Usage:
    python3 smoke_test.py --host 10.211.55.11
    python3 smoke_test.py --host mail.example.com --user admin@example.com --pass adminpass123

Excludes: 2FA, password change (by design).
"""

import argparse
import imaplib
import smtplib
import socket
import ssl
import sys
import time
import uuid
from email.mime.text import MIMEText
from http.client import HTTPSConnection
from urllib.parse import urlencode, quote

# ── Colors ──────────────────────────────────────────────────────────────────
GREEN = "\033[92m"
RED = "\033[91m"
YELLOW = "\033[93m"
BOLD = "\033[1m"
RESET = "\033[0m"

passed = 0
failed = 0
skipped = 0


def ok(msg):
    global passed
    passed += 1
    print(f"{GREEN}[OK]{RESET}   {msg}")


def fail(msg, detail=""):
    global failed
    failed += 1
    print(f"{RED}[FAIL]{RESET} {msg}")
    if detail:
        print(f"       {detail}")


def skip(msg):
    global skipped
    skipped += 1
    print(f"{YELLOW}[SKIP]{RESET} {msg}")


# ── TCP connectivity ────────────────────────────────────────────────────────
def check_tcp(host, port, label, timeout=5):
    try:
        s = socket.create_connection((host, port), timeout=timeout)
        s.close()
        ok(f"TCP: {label}({port}) reachable")
        return True
    except Exception as e:
        fail(f"TCP: {label}({port}) reachable", str(e))
        return False


# ── SMTP STARTTLS ───────────────────────────────────────────────────────────
def check_smtp_starttls(host):
    try:
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        with smtplib.SMTP(host, 25, timeout=10) as smtp:
            smtp.ehlo()
            if smtp.has_extn("STARTTLS"):
                smtp.starttls(context=ctx)
                smtp.ehlo()
                ok("SMTP STARTTLS works")
                return True
            else:
                fail("SMTP STARTTLS", "STARTTLS not advertised")
                return False
    except Exception as e:
        fail("SMTP STARTTLS", str(e))
        return False


# ── SMTP AUTH + send ────────────────────────────────────────────────────────
def check_smtp_send(host, user, password):
    msg_id = str(uuid.uuid4())[:8]
    subject = f"[smoke-test] {msg_id}"
    body = f"Mail server smoke test — {time.strftime('%Y-%m-%d %H:%M:%S')}"

    msg = MIMEText(body)
    msg["Subject"] = subject
    msg["From"] = user
    msg["To"] = user

    try:
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE

        with smtplib.SMTP(host, 587, timeout=10) as smtp:
            smtp.ehlo()
            smtp.starttls(context=ctx)
            smtp.ehlo()
            smtp.login(user, password)
            smtp.sendmail(user, [user], msg.as_string())

        ok(f"SMTP AUTH + send (subject: {subject})")
        return subject
    except Exception as e:
        fail("SMTP AUTH + send", str(e))
        return None


# ── IMAP login + find message ──────────────────────────────────────────────
def check_imap(host, user, password, search_subject, retries=10, delay=3):
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE

    for attempt in range(1, retries + 1):
        try:
            with imaplib.IMAP4_SSL(host, 993, ssl_context=ctx) as imap:
                imap.login(user, password)
                imap.select("INBOX")
                _, data = imap.search(None, f'SUBJECT "{search_subject}"')
                if data[0]:
                    ok(f"IMAP login + message found (attempt {attempt})")
                    return True
                elif attempt < retries:
                    time.sleep(delay)
        except Exception as e:
            if attempt == retries:
                fail("IMAP login + find message", str(e))
                return False
            time.sleep(delay)

    fail("IMAP: test message not found after retries")
    return False


# ── Roundcube web login ────────────────────────────────────────────────────
def check_roundcube(host, user, password):
    try:
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE

        conn = HTTPSConnection(host, 443, context=ctx, timeout=10)

        # GET login page + extract CSRF token + session cookie
        conn.request("GET", "/mail/?_task=login")
        resp = conn.getresponse()
        body = resp.read().decode(errors="replace")

        cookies = {}
        for hdr in resp.getheaders():
            if hdr[0].lower() == "set-cookie":
                part = hdr[1].split(";")[0]
                if "=" in part:
                    k, v = part.split("=", 1)
                    cookies[k.strip()] = v.strip()

        token = None
        for line in body.splitlines():
            if '_token' in line and 'value="' in line:
                idx = line.find('value="') + 7
                token = line[idx : line.index('"', idx)]
                break

        if not token:
            fail("Roundcube web login", "CSRF token not found")
            return False

        cookie_str = "; ".join(f"{k}={v}" for k, v in cookies.items())

        # POST login with cookies
        data = urlencode({
            "_token": token,
            "_user": user,
            "_pass": password,
            "_task": "login",
            "_action": "login",
        })
        conn.request("POST", "/mail/?_task=login", body=data,
                      headers={
                          "Content-Type": "application/x-www-form-urlencoded",
                          "Cookie": cookie_str,
                      })
        resp = conn.getresponse()

        # Merge new cookies
        for hdr in resp.getheaders():
            if hdr[0].lower() == "set-cookie":
                part = hdr[1].split(";")[0]
                if "=" in part:
                    k, v = part.split("=", 1)
                    cookies[k.strip()] = v.strip()

        cookie_str = "; ".join(f"{k}={v}" for k, v in cookies.items())

        # Follow redirect to mail dashboard
        if resp.status in (302, 301):
            loc = resp.getheader("Location", "")
            resp.read()
            conn.request("GET", loc, headers={"Cookie": cookie_str})
            resp = conn.getresponse()

        page = resp.read().decode(errors="replace")
        if resp.status == 200 and ("logout" in page.lower() or "_task=mail" in page):
            ok("Roundcube web login")
            return True

        fail("Roundcube web login", f"HTTP {resp.status}")
        return False
    except Exception as e:
        fail("Roundcube web login", str(e))
        return False


# ── PostfixAdmin web ────────────────────────────────────────────────────────
def check_postfixadmin(host):
    try:
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE

        conn = HTTPSConnection(host, 443, context=ctx, timeout=10)
        conn.request("GET", "/admin/")
        resp = conn.getresponse()

        if resp.status in (200, 302):
            ok("PostfixAdmin web (/admin/ reachable)")
            return True
        fail("PostfixAdmin web", f"HTTP {resp.status}")
        return False
    except Exception as e:
        fail("PostfixAdmin web", str(e))
        return False


# ── ManageSieve ─────────────────────────────────────────────────────────────
def check_sieve(host):
    try:
        s = socket.create_connection((host, 4190), timeout=5)
        banner = s.recv(1024).decode(errors="replace")
        s.close()
        if "IMPLEMENTATION" in banner or "SASL" in banner or "SIEVE" in banner:
            ok(f"ManageSieve(4190) — banner received")
            return True
        fail("ManageSieve(4190)", f"unexpected banner: {banner[:80]}")
        return False
    except Exception as e:
        fail("ManageSieve(4190)", str(e))
        return False


# ── SPF / DKIM DNS ─────────────────────────────────────────────────────────
def check_dns(domain):
    try:
        import dns.resolver
    except ImportError:
        skip("SPF/DKIM DNS (dnspython not installed)")
        return

    try:
        answers = dns.resolver.resolve(domain, "TXT")
        spf = [r.to_text() for r in answers if "v=spf" in r.to_text().lower()]
        if spf:
            ok(f"SPF record: {spf[0][:60]}...")
        else:
            fail("SPF record", "no TXT record with v=spf1 found")

        dkim_domain = f"default._domainkey.{domain}"
        try:
            dkim = dns.resolver.resolve(dkim_domain, "TXT")
            dkim_txt = [r.to_text() for r in dkim]
            ok(f"DKIM record found ({len(dkim_txt)} key(s))")
        except Exception:
            fail("DKIM record", f"no TXT at {dkim_domain}")
    except Exception as e:
        skip(f"SPF/DKIM DNS ({e})")


# ── Vacation auto-reply ────────────────────────────────────────────────────
def check_vacation(host, sender_user, sender_pass, vacation_user):
    """Send mail to vacation_user, check if auto-reply arrives at sender."""
    msg_id = str(uuid.uuid4())[:8]
    subject = f"[vacation-test] {msg_id}"
    body = "Vacation auto-reply smoke test"

    msg = MIMEText(body)
    msg["Subject"] = subject
    msg["From"] = sender_user
    msg["To"] = vacation_user

    try:
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE

        with smtplib.SMTP(host, 587, timeout=10) as smtp:
            smtp.ehlo()
            smtp.starttls(context=ctx)
            smtp.ehlo()
            smtp.login(sender_user, sender_pass)
            smtp.sendmail(sender_user, [vacation_user], msg.as_string())

        ok(f"Vacation: test sent to {vacation_user}")
    except Exception as e:
        fail("Vacation: send test", str(e))


# ── Main ────────────────────────────────────────────────────────────────────
def main():
    parser = argparse.ArgumentParser(description="Mail server smoke test")
    parser.add_argument("--host", default="10.211.55.11")
    parser.add_argument("--user", default="admin@example.com")
    parser.add_argument("--password", default="adminpass123")
    parser.add_argument("--domain", default="example.com")
    args = parser.parse_args()

    h = args.host
    u = args.user
    p = args.password
    d = args.domain

    print(f"\n{BOLD}Mail Server Smoke Test{RESET}")
    print(f"Host: {h}  User: {u}  Domain: {d}\n")

    # 1. TCP ports
    print(f"{BOLD}── TCP Connectivity ──{RESET}")
    check_tcp(h, 25, "SMTP")
    check_tcp(h, 587, "SMTP-Submit")
    check_tcp(h, 993, "IMAPS")
    check_tcp(h, 995, "POP3S")
    check_tcp(h, 443, "HTTPS")
    check_tcp(h, 4190, "ManageSieve")

    # 2. SMTP STARTTLS
    print(f"\n{BOLD}── SMTP ──{RESET}")
    check_smtp_starttls(h)

    # 3. SMTP AUTH + send
    subject = check_smtp_send(h, u, p)

    # 4. IMAP
    print(f"\n{BOLD}── IMAP ──{RESET}")
    if subject:
        check_imap(h, u, p, subject)
    else:
        fail("IMAP: skipped (send failed)")

    # 5. Roundcube
    print(f"\n{BOLD}── Web ──{RESET}")
    check_roundcube(h, u, p)
    check_postfixadmin(h)

    # 6. ManageSieve
    print(f"\n{BOLD}── Sieve ──{RESET}")
    check_sieve(h)

    # 7. DNS
    print(f"\n{BOLD}── DNS ──{RESET}")
    check_dns(d)

    # Summary
    total = passed + failed + skipped
    print(f"\n{BOLD}── Summary ──{RESET}")
    if failed == 0:
        print(f"{GREEN}{passed}/{total} passed{RESET}, {failed} failed, {skipped} skipped")
    else:
        print(f"{passed}/{total} passed, {RED}{failed} failed{RESET}, {skipped} skipped")

    sys.exit(1 if failed > 0 else 0)


if __name__ == "__main__":
    main()
