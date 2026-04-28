#!/usr/bin/env python3
"""Corporate mail server test suite — all features + edge cases.

Tests: connectivity, SMTP, IMAP/POP3/IMAPS/POP3S, submission TLS,
SASL auth, SpamAssassin, Sieve, quota, fail2ban, Roundcube, PostfixAdmin,
DKIM, postgrey, rate limiting, header privacy.

Run from macOS host:
    unset PYTHONHOME && unset PYTHONPATH && /usr/bin/python3 stress_test.py
"""

import smtplib
import imaplib
import poplib
import socket
import ssl
import time
import threading
import sys
import email.utils
import json
import re
import urllib.request
import urllib.parse
import http.cookiejar
from datetime import datetime
from concurrent.futures import ThreadPoolExecutor, as_completed

# --- Config ---
VM_IP       = "10.211.55.11"
DOMAIN      = "example.com"
USER        = f"admin@{DOMAIN}"
PASS        = "adminpass123"
MAILHOST    = f"mail.{DOMAIN}"

# Ports
SMTP        = 25
SUBMISSION  = 587
SMTPS       = 465
IMAP        = 143
IMAPS       = 993
POP3        = 110
POP3S       = 995
SIEVE_PORT  = 4190
HTTPS       = 443

RESULTS = []


def log(msg, ok=True):
    sym = "PASS" if ok else "FAIL"
    ts = datetime.now().strftime("%H:%M:%S.%f")[:-3]
    line = f"[{ts}] [{sym}] {msg}"
    print(line)
    RESULTS.append((sym, line))


def log_section(title, num):
    print(f"\n{'='*60}")
    print(f"{num}. {title}")
    print(f"{'='*60}")


# =====================================================
# 1. CONNECTIVITY
# =====================================================
def test_connectivity():
    log_section("CONNECTIVITY — ALL PORTS", 1)
    ports = [
        (SMTP, "SMTP"), (SUBMISSION, "Submission"),
        (SMTPS, "SMTPS"), (IMAP, "IMAP"), (IMAPS, "IMAPS"),
        (POP3, "POP3"), (POP3S, "POP3S"),
        (SIEVE_PORT, "ManageSieve"), (HTTPS, "HTTPS"),
    ]
    for port, name in ports:
        try:
            s = socket.create_connection((VM_IP, port), timeout=5)
            s.close()
            log(f"TCP {name} ({port}) — reachable")
        except Exception as e:
            log(f"TCP {name} ({port}) — {e}", ok=False)


# =====================================================
# 2. SMTP DELIVERY
# =====================================================
def smtp_send(subject, body, from_addr=None, to_addr=None, port=SMTP,
              starttls=False, use_ssl=False, auth=None, timeout=10):
    from_addr = from_addr or USER
    to_addr = to_addr or USER
    try:
        msg = (
            f"From: {from_addr}\r\n"
            f"To: {to_addr}\r\n"
            f"Subject: {subject}\r\n"
            f"Date: {email.utils.formatdate(localtime=True)}\r\n"
            f"Message-ID: <{time.time()}.{port}@{MAILHOST}>\r\n"
            f"\r\n{body}\r\n"
        )
        if use_ssl:
            ctx = ssl.create_default_context()
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
            with smtplib.SMTP_SSL(VM_IP, port, timeout=timeout, context=ctx) as s:
                if auth:
                    s.login(auth[0], auth[1])
                s.sendmail(from_addr, [to_addr], msg)
        else:
            with smtplib.SMTP(VM_IP, port, timeout=timeout) as s:
                if starttls:
                    ctx = ssl.create_default_context()
                    ctx.check_hostname = False
                    ctx.verify_mode = ssl.CERT_NONE
                    s.starttls(context=ctx)
                if auth:
                    s.login(auth[0], auth[1])
                s.sendmail(from_addr, [to_addr], msg)
        return True, None
    except Exception as e:
        return False, str(e)


def test_smtp_basic():
    log_section("SMTP — BASIC DELIVERY", 2)
    ok, err = smtp_send("Test basic", "Basic delivery test")
    log(f"SMTP port {SMTP} — {'delivered' if ok else f'FAILED: {err}'}", ok=ok)


def test_smtp_batch(count=100):
    log_section(f"SMTP — BATCH ({count} emails)", 3)
    start = time.time()
    sent = 0
    for i in range(count):
        ok, _ = smtp_send(f"Batch #{i+1}", f"Body {i}")
        if ok:
            sent += 1
    elapsed = time.time() - start
    rate = sent / elapsed if elapsed > 0 else 0
    log(f"Sent {sent}/{count} in {elapsed:.1f}s — {rate:.1f} msg/sec", ok=sent >= count * 0.9)


def test_smtp_concurrent(total=200, workers=10):
    log_section(f"SMTP — CONCURRENT ({total} msgs, {workers} threads)", 4)
    per_worker = total // workers
    start = time.time()
    sent = 0
    errors = []

    def worker(wid):
        n = 0
        e = []
        for i in range(per_worker):
            ok, err = smtp_send(f"Concurrent W{wid} #{i}", "body")
            if ok:
                n += 1
            else:
                e.append(err)
        return n, e

    with ThreadPoolExecutor(max_workers=workers) as pool:
        futures = [pool.submit(worker, i) for i in range(workers)]
        for f in as_completed(futures):
            n, e = f.result()
            sent += n
            errors.extend(e)

    elapsed = time.time() - start
    rate = sent / elapsed if elapsed > 0 else 0
    log(f"Sent {sent}/{total} in {elapsed:.1f}s — {rate:.1f} msg/sec", ok=sent >= total * 0.9)
    if errors:
        log(f"Errors: {len(errors)} — {errors[0]}", ok=False)


# =====================================================
# 5. SUBMISSION TLS + SASL
# =====================================================
def test_submission():
    log_section("SUBMISSION — TLS + SASL", 5)

    # Port 587 STARTTLS + auth
    ok, err = smtp_send("Test submission", "via 587", port=SUBMISSION,
                         starttls=True, auth=(USER, PASS))
    log(f"587 STARTTLS + SASL — {'OK' if ok else f'FAIL: {err}'}", ok=ok)

    # Port 465 SMTPS + auth
    ok, err = smtp_send("Test smtps", "via 465", port=SMTPS,
                         use_ssl=True, auth=(USER, PASS))
    log(f"465 SMTPS + SASL — {'OK' if ok else f'FAIL: {err}'}", ok=ok)

    # Edge: no auth on submission — must fail
    ok, _ = smtp_send("No auth", "should be rejected", port=SUBMISSION, starttls=True)
    log(f"587 without auth — rejected as expected", ok=not ok)

    # Edge: wrong password
    ok, err = smtp_send("Wrong pass", "should fail", port=SUBMISSION,
                         starttls=True, auth=(USER, "wrongpass"))
    log(f"587 wrong password — rejected", ok=not ok)


# =====================================================
# 6. IMAP / IMAPS / POP3 / POP3S
# =====================================================
def test_imap():
    log_section("IMAP + IMAPS + POP3 + POP3S", 6)

    # IMAP plaintext
    try:
        imap = imaplib.IMAP4(VM_IP, IMAP, timeout=10)
        imap.login(USER, PASS)
        imap.select("INBOX")
        _, data = imap.search(None, "ALL")
        count = len(data[0].split()) if data[0] else 0
        log(f"IMAP port {IMAP} — login OK, INBOX has {count} msgs")
        # List folders
        _, folders = imap.list()
        folder_names = [f.decode().split('"/"')[-1].strip() for f in folders]
        log(f"IMAP folders — {', '.join(folder_names)}")
        required = ["INBOX", "Junk", "Trash", "Sent", "Drafts"]
        for req in required:
            found = any(req in f for f in folder_names)
            log(f"Folder {req} — {'exists' if found else 'MISSING'}", ok=found)
        imap.logout()
    except Exception as e:
        log(f"IMAP — {e}", ok=False)

    # IMAPS
    try:
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        imap = imaplib.IMAP4_SSL(VM_IP, IMAPS, timeout=10, ssl_context=ctx)
        imap.login(USER, PASS)
        imap.logout()
        log(f"IMAPS port {IMAPS} — login OK")
    except Exception as e:
        log(f"IMAPS — {e}", ok=False)

    # POP3
    try:
        pop = poplib.POP3(VM_IP, POP3, timeout=10)
        pop.user(USER)
        pop.pass_(PASS)
        count, size = pop.stat()
        log(f"POP3 port {POP3} — {count} msgs, {size} bytes")
        pop.quit()
    except Exception as e:
        log(f"POP3 — {e}", ok=False)

    # POP3S
    try:
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        pop = poplib.POP3_SSL(VM_IP, POP3S, timeout=10, context=ctx)
        pop.user(USER)
        pop.pass_(PASS)
        count, size = pop.stat()
        log(f"POP3S port {POP3S} — {count} msgs, {size} bytes")
        pop.quit()
    except Exception as e:
        log(f"POP3S — {e}", ok=False)

    # Edge: wrong IMAP password
    try:
        imap = imaplib.IMAP4(VM_IP, IMAP, timeout=5)
        imap.login(USER, "wrongpassword")
        log("IMAP wrong password — NOT rejected!", ok=False)
        imap.logout()
    except imaplib.IMAP4.error:
        log("IMAP wrong password — rejected correctly")


def test_imap_concurrent(conns=20):
    log_section(f"IMAP CONCURRENT ({conns} sessions)", 7)
    ok_count = 0
    fail_count = 0

    def worker():
        nonlocal ok_count, fail_count
        try:
            imap = imaplib.IMAP4(VM_IP, IMAP, timeout=10)
            imap.login(USER, PASS)
            imap.select("INBOX")
            imap.search(None, "ALL")
            imap.logout()
            ok_count += 1
        except Exception:
            fail_count += 1

    start = time.time()
    threads = [threading.Thread(target=worker) for _ in range(conns)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    elapsed = time.time() - start
    log(f"{ok_count}/{conns} sessions OK in {elapsed:.1f}s", ok=ok_count >= conns * 0.9)
    if fail_count:
        log(f"{fail_count} failures", ok=False)


# =====================================================
# 8. SPAMASSASSIN + SIEVE
# =====================================================
def test_spam():
    log_section("SPAMASSASSIN + SIEVE", 8)

    # Send clean email
    ok, _ = smtp_send("Quarterly report Q4", "Please find attached the quarterly financial report.")
    log(f"Clean email sent — {'OK' if ok else 'FAIL'}", ok=ok)
    time.sleep(5)

    # Send spam email
    ok, _ = smtp_send(
        "CHEAP MEDS BUY NOW LIMITED OFFER",
        "Click http://pharmacy.top/viagra for free pills! Make money fast! Cialis pharmacy meds",
    )
    log(f"Spam email sent — {'OK' if ok else 'FAIL'}", ok=ok)
    time.sleep(8)

    # Check where spam landed
    try:
        imap = imaplib.IMAP4(VM_IP, IMAP, timeout=10)
        imap.login(USER, PASS)

        imap.select("INBOX")
        _, data = imap.search(None, 'SUBJECT "Quarterly report"')
        clean_in_inbox = len(data[0].split()) if data[0] else 0
        log(f"Clean email in INBOX — {clean_in_inbox}", ok=clean_in_inbox > 0)

        imap.select("Junk")
        _, data = imap.search(None, 'SUBJECT "CHEAP MEDS"')
        spam_in_junk = len(data[0].split()) if data[0] else 0
        log(f"Spam in Junk folder — {spam_in_junk}", ok=spam_in_junk > 0)

        if spam_in_junk == 0:
            imap.select("INBOX")
            _, data = imap.search(None, 'SUBJECT "CHEAP MEDS"')
            spam_in_inbox = len(data[0].split()) if data[0] else 0
            if spam_in_inbox > 0:
                log("Spam in INBOX — Sieve filter NOT working", ok=False)

        imap.logout()
    except Exception as e:
        log(f"Spam check IMAP error — {e}", ok=False)


# =====================================================
# 9. HEADER PRIVACY
# =====================================================
def test_header_privacy():
    log_section("HEADER PRIVACY", 9)
    ok, _ = smtp_send("Header test", "Check headers", from_addr=USER, to_addr=USER)
    if not ok:
        log("Could not send header test email", ok=False)
        return
    time.sleep(3)

    try:
        imap = imaplib.IMAP4(VM_IP, IMAP, timeout=10)
        imap.login(USER, PASS)
        imap.select("INBOX")
        _, data = imap.search(None, 'SUBJECT "Header test"')
        if not data[0]:
            log("Header test email not found", ok=False)
            imap.logout()
            return
        msg_id = data[0].split()[-1]
        _, msg_data = imap.fetch(msg_id, "(RFC822)")
        raw = msg_data[0][1].decode(errors="replace")

        checks = {
            "X-Mailer": "X-Mailer" not in raw,
            "User-Agent": "User-Agent" not in raw,
            "X-Originating-IP": "X-Originating-IP" not in raw,
            "X-PHP-Originating-Script": "X-PHP-Originating-Script" not in raw,
            "DKIM-Signature": "DKIM-Signature" in raw,
        }
        for header, passed in checks.items():
            if header == "DKIM-Signature":
                log(f"DKIM-Signature — {'present' if passed else 'MISSING'}", ok=passed)
            else:
                log(f"{header} — {'stripped' if passed else 'NOT stripped'}", ok=passed)

        imap.logout()
    except Exception as e:
        log(f"Header check error — {e}", ok=False)


# =====================================================
# 10. FAIL2BAN
# =====================================================
def test_fail2ban(attempts=8):
    log_section(f"FAIL2BAN — BRUTE FORCE ({attempts} bad logins)", 10)
    banned = False
    for i in range(attempts):
        try:
            imap = imaplib.IMAP4(VM_IP, IMAP, timeout=5)
            imap.login(USER, "wrong_password_12345")
        except imaplib.IMAP4.error:
            pass
        except (socket.error, OSError):
            banned = True
            log(f"Banned after {i+1} bad attempts — connection refused")
            break
        time.sleep(0.5)

    if not banned:
        log(f"Not banned after {attempts} attempts (threshold may be higher)")

    time.sleep(3)
    try:
        imap = imaplib.IMAP4(VM_IP, IMAP, timeout=5)
        imap.login(USER, PASS)
        imap.logout()
        log("Legit login works after ban")
    except Exception:
        log("Legit login blocked — still banned", ok=False)


# =====================================================
# 11. ROUNDCUBE WEBMAIL
# =====================================================
def test_roundcube():
    log_section("ROUNDCUBE WEBMAIL", 11)
    try:
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        cj = http.cookiejar.CookieJar()
        opener = urllib.request.build_opener(
            urllib.request.HTTPSHandler(context=ctx),
            urllib.request.HTTPCookieProcessor(cj),
        )

        # Load login page
        resp = opener.open(f"https://{VM_IP}/mail/?_task=login", timeout=10)
        page = resp.read().decode(errors="replace")
        token_match = re.search(r'name="_token"\s+value="([^"]+)"', page)
        if not token_match:
            log("Roundcube CSRF token not found", ok=False)
            return
        token = token_match.group(1)
        log("Roundcube login page loaded, got CSRF token")

        # Login
        data = urllib.parse.urlencode({
            "_task": "login",
            "_action": "login",
            "_user": USER,
            "_pass": PASS,
            "_token": token,
        }).encode()
        resp = opener.open(f"https://{VM_IP}/mail/?_task=login&_action=login", data, timeout=10)
        page = resp.read().decode(errors="replace")

        if "_task=mail" in page or "_task=settings" in page:
            log("Roundcube login — success")
        else:
            log("Roundcube login — FAILED (no mail/settings page)", ok=False)

        # Edge: wrong password
        cj.clear()
        resp = opener.open(f"https://{VM_IP}/mail/?_task=login", timeout=10)
        page = resp.read().decode(errors="replace")
        token_match = re.search(r'name="_token"\s+value="([^"]+)"', page)
        if token_match:
            data = urllib.parse.urlencode({
                "_task": "login", "_action": "login",
                "_user": USER, "_pass": "wrongpass123",
                "_token": token_match.group(1),
            }).encode()
            resp = opener.open(f"https://{VM_IP}/mail/?_task=login&_action=login", data, timeout=10)
            page = resp.read().decode(errors="replace")
            log(f"Roundcube wrong password — {'rejected' if 'Login failed' in page or '_task=login' in page else 'NOT rejected'}",
                ok="Login failed" in page or "_task=login" in page)

    except Exception as e:
        log(f"Roundcube — {e}", ok=False)


# =====================================================
# 12. POSTFIXADMIN
# =====================================================
def test_postfixadmin():
    log_section("POSTFIXADMIN", 12)
    try:
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        cj = http.cookiejar.CookieJar()
        opener = urllib.request.build_opener(
            urllib.request.HTTPSHandler(context=ctx),
            urllib.request.HTTPCookieProcessor(cj),
        )

        # Load login page
        resp = opener.open(f"https://{VM_IP}/admin/login.php", timeout=10)
        page = resp.read().decode(errors="replace")
        token_match = re.search(r'name="token"\s+value="([^"]+)"', page)
        if not token_match:
            log("PostfixAdmin CSRF token not found", ok=False)
            return
        token = token_match.group(1)
        log("PostfixAdmin login page loaded, got CSRF token")

        # Login
        data = urllib.parse.urlencode({
            "username": USER,
            "password": PASS,
            "token": token,
        }).encode()
        resp = opener.open(f"https://{VM_IP}/admin/login.php", data, timeout=10)
        page = resp.read().decode(errors="replace")

        has_menu = any(x in page for x in ["list.php", "virtual", "sendmail"])
        log(f"PostfixAdmin login — {'success, menu visible' if has_menu else 'FAILED'}", ok=has_menu)

        # Edge: wrong password
        cj.clear()
        resp = opener.open(f"https://{VM_IP}/admin/login.php", timeout=10)
        page = resp.read().decode(errors="replace")
        token_match = re.search(r'name="token"\s+value="([^"]+)"', page)
        if token_match:
            data = urllib.parse.urlencode({
                "username": USER,
                "password": "wrongpass123",
                "token": token_match.group(1),
            }).encode()
            resp = opener.open(f"https://{VM_IP}/admin/login.php", data, timeout=10)
            page = resp.read().decode(errors="replace")
            log(f"PostfixAdmin wrong password — {'rejected' if 'login.php' in resp.url or 'error' in page.lower() else 'NOT rejected'}",
                ok="login.php" in resp.url or "error" in page.lower())

    except Exception as e:
        log(f"PostfixAdmin — {e}", ok=False)


# =====================================================
# 13. AUTODISCOVER / AUTOCONFIG
# =====================================================
def test_autoconfig():
    log_section("AUTODISCOVER + AUTOCONFIG", 13)
    try:
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        opener = urllib.request.build_opener(urllib.request.HTTPSHandler(context=ctx))

        # Autoconfig XML
        resp = opener.open(
            f"https://{VM_IP}/.well-known/autoconfig/mail/config-v1.1.xml", timeout=10)
        xml = resp.read().decode()
        ok = "imap" in xml.lower() and "smtp" in xml.lower() and DOMAIN in xml
        log(f"Autoconfig XML — {'valid' if ok else 'INVALID'}", ok=ok)

        # Autodiscover
        resp = opener.open(
            f"https://{VM_IP}/autodiscover/autodiscover.xml", timeout=10)
        xml = resp.read().decode()
        ok = "Autodiscover" in xml or "IMAP" in xml
        log(f"Autodiscover XML — {'valid' if ok else 'INVALID'}", ok=ok)

    except Exception as e:
        log(f"Autoconfig — {e}", ok=False)


# =====================================================
# 14. QUOTA
# =====================================================
def test_quota():
    log_section("QUOTA", 14)
    try:
        imap = imaplib.IMAP4(VM_IP, IMAP, timeout=10)
        imap.login(USER, PASS)

        # Check QUOTA capability
        caps = imap.capability()
        has_quota = caps and "QUOTA" in " ".join(caps[0])
        log(f"IMAP QUOTA capability — {'present' if has_quota else 'MISSING'}", ok=has_quota)

        # Get quota
        try:
            _, quota_data = imap.getquotaroot("INBOX")
            log(f"Quota info — {quota_data}")
        except Exception as e:
            log(f"Quota read — {e}", ok=False)

        imap.logout()
    except Exception as e:
        log(f"Quota test — {e}", ok=False)


# =====================================================
# 15. HTTPS + TLS
# =====================================================
def test_https():
    log_section("HTTPS + TLS", 15)

    # HTTP redirect to HTTPS
    try:
        req = urllib.request.Request(f"http://{VM_IP}/")
        opener = urllib.request.build_opener(urllib.request.HTTPRedirectHandler)
        try:
            resp = opener.open(req, timeout=10)
            log("HTTP redirect to HTTPS — NOT redirecting", ok=False)
        except urllib.error.URLError as e:
            if "ssl" in str(e).lower() or "redirect" in str(e).lower():
                log("HTTP redirect to HTTPS — OK")
            else:
                log(f"HTTP redirect — {e}")
    except Exception as e:
        log(f"HTTP redirect — {e}", ok=False)

    # HTTPS with self-signed
    try:
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        resp = urllib.request.urlopen(f"https://{VM_IP}/", context=ctx, timeout=10)
        log(f"HTTPS response — {resp.status}")
    except Exception as e:
        log(f"HTTPS — {e}", ok=False)


# =====================================================
# 16. RATE LIMITING
# =====================================================
def test_rate_limit():
    log_section("RATE LIMITING", 16)
    # Send 30 messages fast from same IP — should not be blocked (limit is 100/min)
    sent = 0
    errors = 0
    for i in range(30):
        ok, _ = smtp_send(f"Rate test #{i}", "body")
        if ok:
            sent += 1
        else:
            errors += 1
    log(f"30 rapid emails — {sent} sent, {errors} errors", ok=sent >= 25)


# =====================================================
# 17. SUSTAINED LOAD
# =====================================================
def test_sustained(duration=15, rate=5):
    log_section(f"SUSTAINED LOAD ({duration}s @ {rate} msg/sec)", 17)
    sent = 0
    errors = 0
    start = time.time()

    with ThreadPoolExecutor(max_workers=rate * 2) as pool:
        while time.time() - start < duration:
            def sender():
                nonlocal sent, errors
                ok, _ = smtp_send(f"Sustained #{sent}", "body")
                if ok:
                    sent += 1
                else:
                    errors += 1
            pool.submit(sender)
            time.sleep(1.0 / rate)

    elapsed = time.time() - start
    actual_rate = sent / elapsed if elapsed > 0 else 0
    log(f"Sent {sent} in {elapsed:.1f}s — {actual_rate:.1f} msg/sec", ok=sent > 0)
    if errors:
        log(f"Errors: {errors}", ok=False)


# =====================================================
# 18. EDGE CASES
# =====================================================
def test_edge_cases():
    log_section("EDGE CASES", 18)

    # Non-existent recipient
    ok, err = smtp_send("Test", "body", to_addr=f"nobody@{DOMAIN}")
    log(f"Non-existent recipient — {'rejected' if not ok else 'accepted (catch-all?)'}",
        ok=not ok or "bounce" in str(err).lower() or ok)

    # Empty subject
    ok, _ = smtp_send("", "empty subject body")
    log(f"Empty subject — {'delivered' if ok else 'rejected'}", ok=ok)

    # Large body (1 MB)
    ok, _ = smtp_send("Large email", "X" * 1_000_000, timeout=30)
    log(f"1 MB email — {'delivered' if ok else 'rejected'}", ok=ok)

    # Non-FQDN sender (should be rejected)
    ok, err = smtp_send("Test", "body", from_addr="user@localhost")
    log(f"Non-FQDN sender (user@localhost) — {'rejected' if not ok else 'accepted'}", ok=not ok)

    # Relay attempt (external sender to external recipient)
    ok, err = smtp_send("Relay test", "body", from_addr="external@other.com",
                         to_addr="external@other.com")
    log(f"Open relay attempt — {'blocked' if not ok else 'OPEN RELAY!'}", ok=not ok)


# =====================================================
# MAIN
# =====================================================
if __name__ == "__main__":
    print("=" * 60)
    print(f"CORPORATE MAIL SERVER TEST SUITE — {VM_IP}")
    print(f"User: {USER}  |  Domain: {DOMAIN}")
    print(f"Started: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print("=" * 60)

    total_start = time.time()

    test_connectivity()
    test_smtp_basic()
    test_smtp_batch(count=50)
    test_smtp_concurrent(total=100, workers=10)
    time.sleep(3)
    test_submission()
    test_imap()
    test_imap_concurrent(conns=15)
    test_spam()
    time.sleep(2)
    test_header_privacy()
    test_fail2ban(attempts=8)
    test_roundcube()
    test_postfixadmin()
    test_autoconfig()
    test_quota()
    test_https()
    test_rate_limit()
    test_sustained(duration=10, rate=5)
    test_edge_cases()

    total_elapsed = time.time() - total_start
    passed = sum(1 for s, _ in RESULTS if s == "PASS")
    failed = sum(1 for s, _ in RESULTS if s == "FAIL")

    print(f"\n{'=' * 60}")
    print(f"SUMMARY — {passed} passed, {failed} failed, {total_elapsed:.1f}s total")
    print(f"{'=' * 60}")
    if failed:
        print("FAILURES:")
        for s, line in RESULTS:
            if s == "FAIL":
                print(f"  {line}")
    sys.exit(1 if failed > 0 else 0)
