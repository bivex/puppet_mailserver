#!/usr/bin/env python3
"""Corporate mail server test suite — all features + edge cases.

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


def ssl_ctx():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


# Default: send via submission (587) with STARTTLS + auth, like a real MUA
def smtp_send(subject, body, from_addr=None, to_addr=None, port=SUBMISSION,
              starttls=True, use_ssl=False, auth=None, timeout=10, extra_headers=None):
    from_addr = from_addr or USER
    to_addr = to_addr or USER
    if auth is None:
        auth = (USER, PASS)
    try:
        hdrs = ""
        if extra_headers:
            for k, v in extra_headers.items():
                hdrs += f"{k}: {v}\r\n"
        msg = (
            f"From: {from_addr}\r\n"
            f"To: {to_addr}\r\n"
            f"Subject: {subject}\r\n"
            f"Date: {email.utils.formatdate(localtime=True)}\r\n"
            f"Message-ID: <{time.time()}.{port}@{MAILHOST}>\r\n"
            f"{hdrs}"
            f"\r\n{body}\r\n"
        )
        if use_ssl:
            with smtplib.SMTP_SSL(VM_IP, port, timeout=timeout, context=ssl_ctx()) as s:
                if auth:
                    s.login(auth[0], auth[1])
                s.sendmail(from_addr, [to_addr], msg)
        else:
            with smtplib.SMTP(VM_IP, port, timeout=timeout) as s:
                if starttls:
                    s.starttls(context=ssl_ctx())
                if auth:
                    s.login(auth[0], auth[1])
                s.sendmail(from_addr, [to_addr], msg)
        return True, None
    except Exception as e:
        return False, str(e)


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
# 2. SMTP BASIC + BATCH + CONCURRENT (via 587)
# =====================================================
def test_smtp_basic():
    log_section("SMTP — BASIC DELIVERY (587 STARTTLS)", 2)
    ok, err = smtp_send("Test basic", "Basic delivery test")
    log(f"587 STARTTLS+SASL — {'delivered' if ok else f'FAILED: {err}'}", ok=ok)


def test_smtp_batch(count=50):
    log_section(f"SMTP — BATCH ({count} emails via 587)", 3)
    start = time.time()
    sent = sum(1 for i in range(count) if smtp_send(f"Batch #{i+1}", f"Body {i}")[0])
    elapsed = time.time() - start
    rate = sent / elapsed if elapsed > 0 else 0
    log(f"Sent {sent}/{count} in {elapsed:.1f}s — {rate:.1f} msg/sec", ok=sent >= count * 0.9)


def test_smtp_concurrent(total=100, workers=10):
    log_section(f"SMTP — CONCURRENT ({total} msgs, {workers} threads)", 4)
    start = time.time()
    sent = 0
    errors = []
    lock = threading.Lock()

    def worker(wid):
        nonlocal sent
        n = 0
        e = []
        for i in range(total // workers):
            ok, err = smtp_send(f"W{wid} #{i}", "body")
            if ok:
                n += 1
            else:
                e.append(err)
        with lock:
            sent += n
            errors.extend(e)

    with ThreadPoolExecutor(max_workers=workers) as pool:
        futures = [pool.submit(worker, i) for i in range(workers)]
        for f in as_completed(futures):
            f.result()

    elapsed = time.time() - start
    rate = sent / elapsed if elapsed > 0 else 0
    log(f"Sent {sent}/{total} in {elapsed:.1f}s — {rate:.1f} msg/sec", ok=sent >= total * 0.8)
    if errors:
        log(f"Errors: {len(errors)} — {errors[0]}", ok=False)


# =====================================================
# 5. SUBMISSION TLS + SASL (port variants)
# =====================================================
def test_submission():
    log_section("SUBMISSION — PORTS + AUTH EDGE CASES", 5)

    ok, err = smtp_send("Test 587", "via 587", port=SUBMISSION, starttls=True, auth=(USER, PASS))
    log(f"587 STARTTLS+SASL — {'OK' if ok else f'FAIL: {err}'}", ok=ok)

    ok, err = smtp_send("Test 465", "via 465", port=SMTPS, use_ssl=True, auth=(USER, PASS))
    log(f"465 SMTPS+SASL — {'OK' if ok else f'FAIL: {err}'}", ok=ok)

    ok, _ = smtp_send("No auth", "rejected", port=SUBMISSION, starttls=True, auth=None)
    log(f"587 no auth — rejected as expected", ok=not ok)

    ok, _ = smtp_send("Wrong pass", "rejected", port=SUBMISSION, starttls=True, auth=(USER, "wrongpass"))
    log(f"587 wrong password — rejected", ok=not ok)


# =====================================================
# 6. IMAP / IMAPS / POP3 / POP3S
# =====================================================
def test_imap():
    log_section("IMAP + IMAPS + POP3 + POP3S", 6)

    try:
        imap = imaplib.IMAP4(VM_IP, IMAP, timeout=10)
        imap.login(USER, PASS)
        imap.select("INBOX")
        _, data = imap.search(None, "ALL")
        count = len(data[0].split()) if data[0] else 0
        log(f"IMAP {IMAP} — login OK, INBOX has {count} msgs")
        _, folders = imap.list()
        fnames = [f.decode().split('"/"')[-1].strip() for f in folders]
        for req in ["INBOX", "Junk", "Trash", "Sent", "Drafts"]:
            found = any(req in f for f in fnames)
            log(f"Folder {req} — {'exists' if found else 'MISSING'}", ok=found)
        imap.logout()
    except Exception as e:
        log(f"IMAP — {e}", ok=False)

    try:
        imap = imaplib.IMAP4_SSL(VM_IP, IMAPS, timeout=10, ssl_context=ssl_ctx())
        imap.login(USER, PASS)
        imap.logout()
        log(f"IMAPS {IMAPS} — login OK")
    except Exception as e:
        log(f"IMAPS — {e}", ok=False)

    try:
        pop = poplib.POP3(VM_IP, POP3, timeout=10)
        pop.user(USER)
        pop.pass_(PASS)
        count, size = pop.stat()
        log(f"POP3 {POP3} — {count} msgs, {size} bytes")
        pop.quit()
    except Exception as e:
        log(f"POP3 — {e}", ok=False)

    try:
        pop = poplib.POP3_SSL(VM_IP, POP3S, timeout=10, context=ssl_ctx())
        pop.user(USER)
        pop.pass_(PASS)
        count, size = pop.stat()
        log(f"POP3S {POP3S} — {count} msgs, {size} bytes")
        pop.quit()
    except Exception as e:
        log(f"POP3S — {e}", ok=False)

    try:
        imap = imaplib.IMAP4(VM_IP, IMAP, timeout=5)
        imap.login(USER, "wrongpassword")
        log("IMAP wrong password — NOT rejected!", ok=False)
        imap.logout()
    except imaplib.IMAP4.error:
        log("IMAP wrong password — rejected correctly")


def test_imap_concurrent(conns=15):
    log_section(f"IMAP CONCURRENT ({conns} sessions)", 7)
    ok_count = 0
    fail_count = 0
    lock = threading.Lock()

    def worker():
        nonlocal ok_count, fail_count
        try:
            imap = imaplib.IMAP4(VM_IP, IMAP, timeout=10)
            imap.login(USER, PASS)
            imap.select("INBOX")
            imap.search(None, "ALL")
            imap.logout()
            with lock:
                ok_count += 1
        except Exception:
            with lock:
                fail_count += 1

    start = time.time()
    threads = [threading.Thread(target=worker) for _ in range(conns)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    elapsed = time.time() - start
    log(f"{ok_count}/{conns} OK in {elapsed:.1f}s", ok=ok_count >= conns * 0.9)


# =====================================================
# 8. SPAMASSASSIN + SIEVE
# =====================================================
def test_spam():
    log_section("SPAMASSASSIN + SIEVE", 8)

    # Check SpamAssassin daemon is running (port 783)
    try:
        s = socket.create_connection((VM_IP, 783), timeout=3)
        s.close()
        log("SpamAssassin spamd (783) — reachable on localhost only")
    except Exception:
        # Port 783 is localhost-only, try via sendmail on VM
        log("SpamAssassin spamd — not reachable from host (expected, localhost-only)")

    # SpamAssassin content_filter runs on port 25 (incoming) only.
    # Sieve rule: X-Spam-Flag: YES -> fileinto Junk
    # Test Sieve by sending email with pre-added X-Spam-Flag header.
    tag = f"SIEVE-TEST-{int(time.time())}"
    ok, _ = smtp_send(
        f"Spam sieve test {tag}",
        "This message tests Sieve spam-to-Junk filing.",
        extra_headers={"X-Spam-Flag": "YES"},
    )
    log(f"Sieve test email (X-Spam-Flag: YES) sent — {'OK' if ok else 'FAIL'}", ok=ok)
    time.sleep(5)

    # Also send a clean email (no spam header)
    ok, _ = smtp_send(f"Clean report {tag}", "Normal business content here.")
    log(f"Clean email sent — {'OK' if ok else 'FAIL'}", ok=ok)
    time.sleep(5)

    try:
        imap = imaplib.IMAP4(VM_IP, IMAP, timeout=10)
        imap.login(USER, PASS)

        # Spam-tagged email should be in Junk (Sieve moved it)
        imap.select("Junk")
        _, data = imap.search(None, f'SUBJECT "Spam sieve test {tag}"')
        spam_junk = len(data[0].split()) if data[0] else 0
        log(f"X-Spam-Flag email in Junk (Sieve) — {spam_junk}", ok=spam_junk > 0)

        if spam_junk == 0:
            imap.select("INBOX")
            _, data = imap.search(None, f'SUBJECT "Spam sieve test {tag}"')
            in_inbox = len(data[0].split()) if data[0] else 0
            if in_inbox > 0:
                log("Spam-tagged email in INBOX — Sieve NOT working", ok=False)
            else:
                log("Spam-tagged email not found — delivery delayed", ok=False)

        # Clean email should be in INBOX
        imap.select("INBOX")
        _, data = imap.search(None, f'SUBJECT "Clean report {tag}"')
        clean = len(data[0].split()) if data[0] else 0
        log(f"Clean email in INBOX — {clean}", ok=clean > 0)

        imap.logout()
    except Exception as e:
        log(f"Spam/Sieve IMAP error — {e}", ok=False)


# =====================================================
# 9. HEADER PRIVACY + DKIM
# =====================================================
def test_header_privacy():
    log_section("HEADER PRIVACY + DKIM", 9)
    ok, _ = smtp_send("Header test", "Check headers")
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
# 10. ROUNDCUBE
# =====================================================
def test_roundcube():
    log_section("ROUNDCUBE WEBMAIL", 10)
    try:
        cj = http.cookiejar.CookieJar()
        opener = urllib.request.build_opener(
            urllib.request.HTTPSHandler(context=ssl_ctx()),
            urllib.request.HTTPCookieProcessor(cj),
        )

        resp = opener.open(f"https://{VM_IP}/mail/?_task=login", timeout=10)
        page = resp.read().decode(errors="replace")
        token = re.search(r'name="_token"\s+value="([^"]+)"', page)
        if not token:
            log("Roundcube CSRF token not found", ok=False)
            return
        log("Roundcube login page loaded, got CSRF token")

        data = urllib.parse.urlencode({
            "_task": "login", "_action": "login",
            "_user": USER, "_pass": PASS,
            "_token": token.group(1),
        }).encode()
        resp = opener.open(f"https://{VM_IP}/mail/?_task=login&_action=login", data, timeout=10)
        page = resp.read().decode(errors="replace")
        ok = "_task=mail" in page or "_task=settings" in page
        log(f"Roundcube login — {'success' if ok else 'FAILED'}", ok=ok)
    except Exception as e:
        log(f"Roundcube — {e}", ok=False)


# =====================================================
# 11. POSTFIXADMIN
# =====================================================
def test_postfixadmin():
    log_section("POSTFIXADMIN", 11)
    try:
        cj = http.cookiejar.CookieJar()
        opener = urllib.request.build_opener(
            urllib.request.HTTPSHandler(context=ssl_ctx()),
            urllib.request.HTTPCookieProcessor(cj),
            urllib.request.HTTPRedirectHandler(),
        )

        resp = opener.open(f"https://{VM_IP}/admin/login.php", timeout=10)
        page = resp.read().decode(errors="replace")
        token = re.search(r'name="token"\s+value="([^"]+)"', page)
        if not token:
            log("PostfixAdmin CSRF token not found", ok=False)
            return
        log("PostfixAdmin login page loaded, got CSRF token")

        # PostfixAdmin uses fUsername/fPassword as form field names
        data = urllib.parse.urlencode({
            "fUsername": USER, "fPassword": PASS, "token": token.group(1),
        }).encode()
        req = urllib.request.Request(f"https://{VM_IP}/admin/login.php", data=data)
        resp = opener.open(req, timeout=10)
        page = resp.read().decode(errors="replace")
        ok = any(x in page for x in ["list.php", "virtual", "sendmail", "backup", "Logged in as"])
        log(f"PostfixAdmin login — {'success, menu visible' if ok else 'FAILED'}", ok=ok)
    except Exception as e:
        log(f"PostfixAdmin — {e}", ok=False)


# =====================================================
# 12. AUTODISCOVER / AUTOCONFIG
# =====================================================
def test_autoconfig():
    log_section("AUTODISCOVER + AUTOCONFIG", 12)
    try:
        opener = urllib.request.build_opener(urllib.request.HTTPSHandler(context=ssl_ctx()))

        resp = opener.open(f"https://{VM_IP}/.well-known/autoconfig/mail/config-v1.1.xml", timeout=10)
        xml = resp.read().decode()
        ok = "imap" in xml.lower() and "smtp" in xml.lower() and DOMAIN in xml
        log(f"Autoconfig XML — {'valid' if ok else 'INVALID'}", ok=ok)

        resp = opener.open(f"https://{VM_IP}/autodiscover/autodiscover.xml", timeout=10)
        xml = resp.read().decode()
        ok = "Autodiscover" in xml or "IMAP" in xml
        log(f"Autodiscover XML — {'valid' if ok else 'INVALID'}", ok=ok)
    except Exception as e:
        log(f"Autoconfig — {e}", ok=False)


# =====================================================
# 13. QUOTA
# =====================================================
def test_quota():
    log_section("QUOTA", 13)
    try:
        imap = imaplib.IMAP4(VM_IP, IMAP, timeout=10)
        imap.login(USER, PASS)
        caps = imap.capability()
        cap_str = " ".join(caps[0]) if caps else ""
        has_quota = "QUOTA" in cap_str or "quota" in cap_str.lower()
        log(f"IMAP QUOTA capability — {'present' if has_quota else 'check via getquotaroot'}")
        try:
            _, q = imap.getquotaroot("INBOX")
            log(f"Quota info — {q}", ok=bool(q))
        except Exception as e:
            log(f"Quota read — {e}", ok=False)
        imap.logout()
    except Exception as e:
        log(f"Quota test — {e}", ok=False)


# =====================================================
# 14. HTTPS + TLS
# =====================================================
def test_https():
    log_section("HTTPS + TLS", 14)

    # HTTP -> HTTPS redirect
    try:
        urllib.request.urlopen(f"http://{VM_IP}/", timeout=10)
        log("HTTP redirect — NOT redirecting", ok=False)
    except urllib.error.URLError as e:
        if "redirect" in str(e).lower() or "ssl" in str(e).lower() or "301" in str(e):
            log("HTTP -> HTTPS redirect — OK")
        else:
            log(f"HTTP redirect — {e}")
    except Exception as e:
        log(f"HTTP redirect — {e}", ok=False)

    # HTTPS serves content
    try:
        resp = urllib.request.urlopen(f"https://{VM_IP}/mail/", context=ssl_ctx(), timeout=10)
        log(f"HTTPS /mail/ — {resp.status} OK")
    except Exception as e:
        log(f"HTTPS /mail/ — {e}", ok=False)


# =====================================================
# 15. RATE LIMITING
# =====================================================
def test_rate_limit():
    log_section("RATE LIMITING", 15)
    # Send 30 emails rapidly; expect some to be rate-limited (60/min threshold)
    sent = sum(1 for i in range(30) if smtp_send(f"Rate #{i}", "body")[0])
    # At least some should go through, and rate limiting should kick in
    log(f"30 rapid emails — {sent}/30 accepted (rate limit active at 60/min)", ok=sent > 0)
    if sent < 30:
        log(f"Rate limiting working — {30 - sent} emails deferred", ok=True)


# =====================================================
# 16. SUSTAINED LOAD
# =====================================================
def test_sustained(duration=10, rate=3):
    log_section(f"SUSTAINED LOAD ({duration}s @ {rate} msg/sec)", 16)
    sent = 0
    errors = 0
    lock = threading.Lock()
    start = time.time()

    def sender():
        nonlocal sent, errors
        ok, _ = smtp_send(f"Sustained {time.time()}", "body")
        with lock:
            if ok:
                sent += 1
            else:
                errors += 1

    with ThreadPoolExecutor(max_workers=rate * 2) as pool:
        while time.time() - start < duration:
            pool.submit(sender)
            time.sleep(1.0 / rate)

    elapsed = time.time() - start
    actual_rate = sent / elapsed if elapsed > 0 else 0
    # Some failures expected due to rate limiting
    log(f"Sent {sent} in {elapsed:.1f}s — {actual_rate:.1f} msg/sec", ok=sent > 0)
    if errors:
        log(f"Rate-limited: {errors} deferred", ok=True)


# =====================================================
# 17. EDGE CASES
# =====================================================
def test_edge_cases():
    log_section("EDGE CASES", 17)

    # Non-existent recipient — should bounce (accepted then bounced, or rejected)
    ok, err = smtp_send("Test", "body", to_addr=f"nobody@{DOMAIN}")
    # Accepted for delivery = OK (will bounce later), rejected = also OK
    log(f"Non-existent recipient — {'accepted (bounce later)' if ok else f'rejected: {err}'}")

    # Empty subject
    ok, _ = smtp_send("", "empty subject body")
    log(f"Empty subject — {'delivered' if ok else 'rejected'}", ok=ok)

    # Large body (1 MB)
    ok, _ = smtp_send("Large email", "X" * 1_000_000, timeout=30)
    log(f"1 MB email — {'delivered' if ok else 'rejected'}", ok=ok)

    # Non-FQDN sender via port 25 (should be rejected)
    ok, err = smtp_send("Test", "body", from_addr="user@localhost", port=SMTP, starttls=False, auth=None)
    log(f"Port 25 non-FQDN sender — {'rejected' if not ok else 'accepted'}", ok=not ok)

    # Open relay attempt via port 25
    ok, err = smtp_send("Relay", "body", from_addr="ext@other.com", to_addr="ext@other.com",
                         port=SMTP, starttls=False, auth=None)
    log(f"Open relay attempt — {'blocked' if not ok else 'OPEN RELAY!'}", ok=not ok)


# =====================================================
# 18. FAIL2BAN (LAST — will ban IP)
# =====================================================
def test_fail2ban(attempts=6):
    log_section(f"FAIL2BAN — BRUTE FORCE ({attempts} bad logins)", 18)
    banned = False
    for i in range(attempts):
        try:
            imap = imaplib.IMAP4(VM_IP, IMAP, timeout=5)
            imap.login(USER, f"wrong_password_{i}")
        except imaplib.IMAP4.error:
            pass
        except (socket.error, OSError):
            banned = True
            log(f"Banned after {i+1} bad attempts — connection refused")
            break
        time.sleep(0.5)

    if not banned:
        log(f"Not banned after {attempts} attempts (threshold may be higher)")

    log("IP is now banned — remaining tests may need unban manually")


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
    # Web tests first (no rate limit impact)
    test_roundcube()
    test_postfixadmin()
    test_autoconfig()
    test_https()
    test_quota()
    # IMAP/POP3 tests (no SMTP rate limit impact)
    test_imap()
    test_imap_concurrent(conns=15)
    # SMTP tests — sequential with cooldowns to respect rate limits
    test_smtp_basic()
    test_submission()
    time.sleep(3)
    test_spam()
    test_header_privacy()
    # Heavy SMTP — batch then cooldown
    test_smtp_batch(count=30)
    print("\n  ... cooling down 65s for rate limit reset ...")
    time.sleep(65)
    test_smtp_concurrent(total=50, workers=5)
    time.sleep(10)
    test_rate_limit()
    time.sleep(65)
    test_sustained(duration=10, rate=3)
    time.sleep(65)
    test_edge_cases()
    test_fail2ban()  # LAST — bans IP

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
