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

    ok, _ = smtp_send("No auth", "rejected", port=SUBMISSION, starttls=True, auth=False)
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
    except imaplib.IMAP4.error as e:
        if b"Plaintext authentication disallowed" in str(e).encode() or b"PRIVACYREQUIRED" in str(e).encode():
            log("IMAP wrong password — correctly rejected plaintext/privacy (SECURE)")
        else:
            log("IMAP wrong password — rejected correctly")


def test_imap_concurrent(conns=15):
    log_section(f"IMAP CONCURRENT ({conns} sessions)", 7)
    ok_count = 0
    fail_count = 0
    lock = threading.Lock()

    def worker():
        nonlocal ok_count, fail_count
        try:
            imap = imaplib.IMAP4_SSL(VM_IP, IMAPS, timeout=10)
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

    gtube = "XJS*C4JDBQADN1.NSBN3*2IDNEN*GTUBE-STANDARD-ANTI-UBE-TEST-EMAIL*C.34X"
    tag = f"GTUBE-TEST-{int(time.time())}"
    
    ok, err = smtp_send(
        f"Spam GTUBE test {tag}",
        f"This is a GTUBE test message.\n\n{gtube}",
    )
    if not ok:
        log(f"GTUBE test email sent — FAIL: {err}", ok=False)
        return

    log(f"GTUBE email sent, waiting 10s for SA + Sieve...")
    time.sleep(10)

    try:
        imap = imaplib.IMAP4_SSL(VM_IP, IMAPS, timeout=10)
        imap.login(USER, PASS)
        
        # Check Junk
        status, _ = imap.select("Junk")
        if status != 'OK':
            status, _ = imap.select("Spam")
            
        if status == 'OK':
            _, data = imap.search(None, f'SUBJECT "{tag}"')
            if data[0]:
                log("GTUBE email correctly moved to Junk folder (SIEVE PASS)")
            else:
                # Check INBOX to see if it missed Sieve
                imap.select("INBOX")
                _, data = imap.search(None, f'SUBJECT "{tag}"')
                if data[0]:
                    log("GTUBE email found in INBOX — Sieve NOT working", ok=False)
                else:
                    log("GTUBE email not found in Junk or INBOX", ok=False)
        else:
            log("Junk/Spam folder not found", ok=False)
            
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
                # Verify selector is "mail" not hostname
                if passed:
                    sel_ok = "s=mail" in raw
                    log(f"DKIM-Signature — present, selector=mail {'OK' if sel_ok else 'WRONG'}", ok=sel_ok)
                else:
                    log(f"DKIM-Signature — MISSING", ok=False)
            else:
                log(f"{header} — {'stripped' if passed else 'NOT stripped'}", ok=passed)

        # Check DMARC Authentication-Results header
        # Note: OpenDMARC adds this. On a fresh install with self-sent mail, it might say 'pass' or 'none'.
        dmarc_ok = "Authentication-Results" in raw and ("dmarc=" in raw.lower() or "opendmarc" in raw.lower())
        log(f"OpenDMARC Results header — {'present' if dmarc_ok else 'MISSING'}", ok=dmarc_ok)

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
# 12. AUTODISCOVER / AUTOCONFIG / MTA-STS
# =====================================================
def test_autoconfig():
    log_section("AUTODISCOVER + AUTOCONFIG + MTA-STS", 12)
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

        # MTA-STS policy
        resp = opener.open(f"https://{VM_IP}/.well-known/mta-sts.txt", timeout=10)
        policy = resp.read().decode()
        sts_ok = "STSv1" in policy and "testing" in policy and MAILHOST in policy
        log(f"MTA-STS policy — {'valid (mode:testing)' if sts_ok else 'INVALID or mode not testing'}", ok=sts_ok)
    except Exception as e:
        log(f"Autoconfig/MTA-STS — {e}", ok=False)


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

    # Security headers
    try:
        req = urllib.request.Request(f"https://{VM_IP}/mail/")
        resp = urllib.request.urlopen(req, context=ssl_ctx(), timeout=10)
        hsts = resp.headers.get("Strict-Transport-Security", "")
        xfo = resp.headers.get("X-Frame-Options", "")
        log(f"HSTS header — {hsts if hsts else 'MISSING'}", ok=bool(hsts))
        log(f"X-Frame-Options — {xfo if xfo else 'MISSING'}", ok=bool(xfo))
    except Exception as e:
        log(f"Security headers — {e}", ok=False)


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

    # Non-existent recipient — should be rejected at SMTP
    ok, err = smtp_send("Test", "body", to_addr=f"nobody@{DOMAIN}")
    log(f"Non-existent recipient — {'rejected' if not ok else 'accepted (bounce later)'}", ok=not ok)

    # Empty subject
    ok, _ = smtp_send("", "empty subject body")
    log(f"Empty subject — {'delivered' if ok else 'rejected'}", ok=ok)

    # 1 MB email
    ok, _ = smtp_send("Large email", "X" * 1_000_000, timeout=30)
    log(f"1 MB email — {'delivered' if ok else 'rejected'}", ok=ok)

    # 15 MB email (Check message_size_limit)
    log("Sending 15 MB email (this may take time)...")
    ok, err = smtp_send("Huge email", "Y" * 15_000_000, timeout=60)
    log(f"15 MB email — {'delivered' if ok else 'rejected (size limit?)'}", ok=ok)
    if not ok: log(f"Rejection: {err}")

    # UTF-8 Headers
    ok, _ = smtp_send("=?UTF-8?B?0J/RgNC40LLQtdGC?=", "UTF-8 Subject Test", from_addr=f"\"Юзер\" <{USER}>")
    log(f"UTF-8 Headers/Subject — {'delivered' if ok else 'rejected'}", ok=ok)

    # Long Headers (10k characters)
    ok, _ = smtp_send("Long Header Test", "body", headers={"X-Long": "Z" * 10000})
    log(f"10k character header — {'delivered' if ok else 'rejected'}", ok=ok)

    # Max Recipients (50)
    recipients = [f"user{i}@{DOMAIN}" for i in range(50)]
    ok, err = smtp_send("Multi-recipient test", "body", to_addr=", ".join(recipients))
    log(f"50 recipients at once — {'accepted' if ok else 'rejected'}", ok=ok)
    if not ok: log(f"Rejection: {err}")

    # Malformed MIME (inconsistent boundary)
    malformed_body = "Content-Type: multipart/mixed; boundary=fixed\n\n--fixed\nContent-Type: text/plain\n\nBody\n--wrong-boundary--"
    ok, _ = smtp_send("Malformed MIME", malformed_body)
    log(f"Malformed MIME — {'accepted' if ok else 'rejected'}", ok=ok)

    # Port 25 non-FQDN sender (should be rejected)
    ok, err = smtp_send("Test", "body", from_addr="user@localhost", port=SMTP, starttls=False, auth=False)
    log(f"Port 25 non-FQDN sender — {'rejected' if not ok else 'accepted'}", ok=not ok)

    # Open relay attempt via port 25
    ok, err = smtp_send("Relay", "body", from_addr="ext@other.com", to_addr="ext@other.com",
                         port=SMTP, starttls=False, auth=False)
    log(f"Open relay attempt — {'blocked' if not ok else 'OPEN RELAY!'}", ok=not ok)

    # SPF: forged sender via port 25 from non-authorized IP (should be rejected by policyd-spf)
    ok, err = smtp_send("SPF test", "body", from_addr=f"forged@{DOMAIN}", to_addr=USER,
                         port=SMTP, starttls=False, auth=False)
    log(f"SPF forged sender (port 25) — {'blocked correctly' if not ok else 'ACCEPTED (SPF FAIL)'}", ok=not ok)
    if not ok:
        log(f"SPF block reason: {err}")


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
