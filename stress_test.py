#!/usr/bin/env python3
"""Mail server load test suite for Puppet-deployed Postfix + Dovecot + SA."""

import smtplib
import imaplib
import poplib
import socket
import ssl
import time
import threading
import sys
import email.utils
from datetime import datetime
from concurrent.futures import ThreadPoolExecutor, as_completed

# --- Config ---
VM_IP       = "10.211.55.11"
SMTP_PORT   = 25
IMAP_PORT   = 143
POP3_PORT   = 110
SIEVE_PORT  = 4190
USER        = "user"
PASS        = "user"
DOMAIN      = "example.com"
RESULTS     = []

def log(msg, ok=True):
    sym = "PASS" if ok else "FAIL"
    ts = datetime.now().strftime("%H:%M:%S.%f")[:-3]
    line = f"[{ts}] [{sym}] {msg}"
    print(line)
    RESULTS.append((sym, line))

# =====================================================
# 1. CONNECTIVITY TESTS
# =====================================================
def test_tcp(port, name, timeout=5):
    try:
        s = socket.create_connection((VM_IP, port), timeout=timeout)
        s.close()
        log(f"TCP {name} ({port}) — reachable")
        return True
    except Exception as e:
        log(f"TCP {name} ({port}) — {e}", ok=False)
        return False

def test_connectivity():
    print("\n" + "="*60)
    print("1. CONNECTIVITY")
    print("="*60)
    ports = [
        (25, "SMTP"), (587, "Submission"), (143, "IMAP"),
        (993, "IMAPS"), (110, "POP3"), (995, "POP3S"),
        (4190, "ManageSieve"),
    ]
    for port, name in ports:
        test_tcp(port, name)

# =====================================================
# 2. SMTP DELIVERY TESTS
# =====================================================
def send_email(subject, body, from_addr=None, to_addr=None, count=1):
    from_addr = from_addr or f"{USER}@{DOMAIN}"
    to_addr = to_addr or f"{USER}@{DOMAIN}"
    delivered = 0
    errors = []
    for i in range(count):
        try:
            msg = (
                f"From: {from_addr}\r\n"
                f"To: {to_addr}\r\n"
                f"Subject: {subject} #{i+1}\r\n"
                f"Date: {email.utils.formatdate(localtime=True)}\r\n"
                f"Message-ID: <{time.time()}.{i}@mail.{DOMAIN}>\r\n"
                f"\r\n{body}\r\n"
            )
            with smtplib.SMTP(VM_IP, SMTP_PORT, timeout=10) as s:
                s.sendmail(from_addr, [to_addr], msg)
            delivered += 1
        except Exception as e:
            errors.append(str(e))
    return delivered, errors

def test_smtp_single():
    print("\n" + "="*60)
    print("2. SMTP SINGLE DELIVERY")
    print("="*60)
    n, err = send_email("Load test single", "Single email test body")
    log(f"SMTP send — {n} delivered, {len(err)} errors" + (f" ({err[0]})" if err else ""))

def test_smtp_batch(count=100):
    print(f"\n3. SMTP BATCH ({count} emails)")
    print("-"*60)
    start = time.time()
    n, err = send_email("Batch test", "Batch email body", count=count)
    elapsed = time.time() - start
    rate = n / elapsed if elapsed > 0 else 0
    log(f"Sent {n}/{count} in {elapsed:.1f}s — {rate:.1f} msg/sec")
    if err:
        log(f"Errors: {len(err)} — {err[0]}", ok=False)
    return n, elapsed

def test_smtp_concurrent(total=200, workers=10):
    print(f"\n4. SMTP CONCURRENT ({total} emails, {workers} threads)")
    print("-"*60)
    per_worker = total // workers
    start = time.time()
    delivered = 0
    errors = []

    def worker(wid):
        n, e = send_email(f"Concurrent W{wid}", f"Worker {wid} body", count=per_worker)
        return n, e

    with ThreadPoolExecutor(max_workers=workers) as pool:
        futures = [pool.submit(worker, i) for i in range(workers)]
        for f in as_completed(futures):
            n, e = f.result()
            delivered += n
            errors.extend(e)

    elapsed = time.time() - start
    rate = delivered / elapsed if elapsed > 0 else 0
    log(f"Sent {delivered}/{total} in {elapsed:.1f}s — {rate:.1f} msg/sec ({workers} threads)")
    if errors:
        log(f"Errors: {len(errors)} — {errors[0]}", ok=False)
    return delivered, elapsed

# =====================================================
# 3. IMAP TESTS
# =====================================================
def test_imap_login():
    print(f"\n5. IMAP LOGIN + READ")
    print("-"*60)
    try:
        imap = imaplib.IMAP4(VM_IP, IMAP_PORT, timeout=10)
        imap.login(USER, PASS)
        log("IMAP login — success")
        imap.select("INBOX")
        status, data = imap.search(None, "ALL")
        count = len(data[0].split()) if data[0] else 0
        log(f"INBOX messages — {count}")
        imap.logout()
        return count
    except Exception as e:
        log(f"IMAP — {e}", ok=False)
        return 0

def test_imap_concurrent(conns=20):
    print(f"\n6. IMAP CONCURRENT ({conns} connections)")
    print("-"*60)
    ok = 0
    fail = 0

    def imap_worker():
        nonlocal ok, fail
        try:
            imap = imaplib.IMAP4(VM_IP, IMAP_PORT, timeout=10)
            imap.login(USER, PASS)
            imap.select("INBOX")
            imap.search(None, "ALL")
            imap.logout()
            ok += 1
        except:
            fail += 1

    start = time.time()
    threads = [threading.Thread(target=imap_worker) for _ in range(conns)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    elapsed = time.time() - start

    log(f"{ok}/{conns} successful IMAP sessions in {elapsed:.1f}s")
    if fail:
        log(f"{fail} IMAP failures", ok=False)

# =====================================================
# 4. POP3 TESTS
# =====================================================
def test_pop3_login():
    print(f"\n7. POP3 LOGIN + LIST")
    print("-"*60)
    try:
        pop = poplib.POP3(VM_IP, POP3_PORT, timeout=10)
        pop.user(USER)
        pop.pass_(PASS)
        count, size = pop.stat()
        log(f"POP3 login — success, {count} messages, {size} bytes")
        pop.quit()
    except Exception as e:
        log(f"POP3 — {e}", ok=False)

# =====================================================
# 5. SPAMASSASSIN TESTS
# =====================================================
def test_spam_detection():
    print(f"\n8. SPAM DETECTION")
    print("-"*60)

    # Clean email
    n, _ = send_email("Quarterly report", "Please find the quarterly report attached.", count=1)
    time.sleep(5)

    # Spam email — send from local domain to pass restrictions
    n_spam, _ = send_email(
        "CHEAP MEDS BUY NOW",
        "Click http://pharmacy.top/viagra for free pills! Make money fast!",
        from_addr=f"{USER}@{DOMAIN}",
        count=1,
    )
    time.sleep(5)

    try:
        imap = imaplib.IMAP4(VM_IP, IMAP_PORT, timeout=10)
        imap.login(USER, PASS)

        # Check INBOX for clean
        imap.select("INBOX")
        _, data = imap.search(None, "ALL")
        inbox_count = len(data[0].split()) if data[0] else 0

        # Check Junk for spam
        imap.select("Junk")
        _, data = imap.search(None, 'SUBJECT "CHEAP MEDS"')
        junk_spam = len(data[0].split()) if data[0] else 0

        imap.logout()

        log(f"INBOX messages after test — {inbox_count}")
        log(f"Spam in Junk folder — {junk_spam}")
        if junk_spam > 0:
            log("Spam correctly filtered to Junk")
        else:
            log("Spam NOT in Junk — sieve/SA issue", ok=False)
    except Exception as e:
        log(f"Spam check IMAP error — {e}", ok=False)

# =====================================================
# 6. FAIL2BAN TEST
# =====================================================
def test_fail2ban_bruteforce(attempts=8):
    # Unban first in case of previous test
    try:
        import subprocess
        subprocess.run(
            ["sshpass", "-p", PASS, "ssh", "-o", "StrictHostKeyChecking=no",
             f"{USER}@{VM_IP}",
             f"echo '{PASS}' | sudo -S fail2ban-client set dovecot unbanip {VM_IP.rsplit('.', 1)[0] + '.2'} 2>/dev/null; "
             f"echo '{PASS}' | sudo -S fail2ban-client set sieve unbanip {VM_IP.rsplit('.', 1)[0] + '.2'} 2>/dev/null"],
            capture_output=True, timeout=10
        )
    except:
        pass
    print(f"\n9. FAIL2BAN BRUTE FORCE TEST ({attempts} bad logins)")
    print("-"*60)
    banned = False
    for i in range(attempts):
        try:
            imap = imaplib.IMAP4(VM_IP, IMAP_PORT, timeout=5)
            imap.login(USER, "wrong_password")
        except imaplib.IMAP4.error:
            pass
        except (socket.error, OSError) as e:
            banned = True
            log(f"Banned after {i+1} attempts — {e}")
            break
        time.sleep(0.5)

    if not banned:
        log(f"Not banned after {attempts} attempts (ban threshold may be higher)")

    # Wait for ban to expire or skip — just report
    time.sleep(2)
    try:
        imap = imaplib.IMAP4(VM_IP, IMAP_PORT, timeout=5)
        imap.login(USER, PASS)
        imap.logout()
        log("Legit login still works after ban period")
    except:
        log("Still banned (legit login blocked) — may need to wait", ok=False)

# =====================================================
# 7. SUSTAINED LOAD TEST
# =====================================================
def test_sustained_load(duration_sec=30, rate_per_sec=5):
    print(f"\n10. SUSTAINED LOAD ({duration_sec}s @ {rate_per_sec} msg/sec)")
    print("-"*60)
    total_target = duration_sec * rate_per_sec
    sent = 0
    errors = 0
    start = time.time()

    def sender():
        nonlocal sent, errors
        try:
            msg = (
                f"From: {USER}@{DOMAIN}\r\n"
                f"To: {USER}@{DOMAIN}\r\n"
                f"Subject: Sustained load #{sent}\r\n"
                f"Date: {email.utils.formatdate(localtime=True)}\r\n"
                f"Message-ID: <{time.time()}@mail.{DOMAIN}>\r\n"
                f"\r\nLoad test body\r\n"
            )
            with smtplib.SMTP(VM_IP, SMTP_PORT, timeout=10) as s:
                s.sendmail(f"{USER}@{DOMAIN}", [f"{USER}@{DOMAIN}"], msg)
            sent += 1
        except:
            errors += 1

    with ThreadPoolExecutor(max_workers=rate_per_sec * 2) as pool:
        while time.time() - start < duration_sec:
            pool.submit(sender)
            time.sleep(1.0 / rate_per_sec)

    elapsed = time.time() - start
    actual_rate = sent / elapsed if elapsed > 0 else 0
    log(f"Sent {sent}/{total_target} in {elapsed:.1f}s — {actual_rate:.1f} msg/sec")
    if errors:
        log(f"Errors: {errors}", ok=False)

# =====================================================
# MAIN
# =====================================================
if __name__ == "__main__":
    print("="*60)
    print(f"MAIL SERVER LOAD TEST — {VM_IP}")
    print(f"Started: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print("="*60)

    total_start = time.time()

    test_connectivity()
    test_smtp_single()
    test_smtp_batch(count=100)
    test_smtp_concurrent(total=200, workers=10)
    time.sleep(3)
    test_imap_login()
    test_imap_concurrent(conns=20)
    test_pop3_login()
    test_spam_detection()
    test_fail2ban_bruteforce(attempts=8)
    test_sustained_load(duration_sec=15, rate_per_sec=5)

    total_elapsed = time.time() - total_start
    passed = sum(1 for s, _ in RESULTS if s == "PASS")
    failed = sum(1 for s, _ in RESULTS if s == "FAIL")

    print("\n" + "="*60)
    print(f"SUMMARY — {passed} passed, {failed} failed, {total_elapsed:.1f}s total")
    print("="*60)
    if failed:
        print("FAILURES:")
        for s, line in RESULTS:
            if s == "FAIL":
                print(f"  {line}")
