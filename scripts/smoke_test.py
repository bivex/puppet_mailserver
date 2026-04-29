#!/usr/bin/env python3
"""Mail server smoke test — verifies full email lifecycle after Puppet deploy.

Usage:
    python3 smoke_test.py --host 10.211.55.11
    python3 smoke_test.py --host mail.example.com --user admin@example.com --password adminpass123

Excludes: 2FA, password change (by design).
"""

import argparse
import base64
import imaplib
import poplib
import smtplib
import socket
import ssl
import subprocess
import sys
import time
import uuid
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText
from email.mime.base import MIMEBase
from email import encoders
from http.client import HTTPSConnection
from urllib.parse import urlencode

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


def make_ssl_ctx():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


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
        ctx = make_ssl_ctx()
        with smtplib.SMTP(host, 25, timeout=10) as smtp:
            smtp.ehlo()
            if smtp.has_extn("STARTTLS"):
                smtp.starttls(context=ctx)
                smtp.ehlo()
                ok("SMTP STARTTLS works")
                return True
            fail("SMTP STARTTLS", "STARTTLS not advertised")
            return False
    except Exception as e:
        fail("SMTP STARTTLS", str(e))
        return False


# ── SMTP AUTH + send to self ────────────────────────────────────────────────
def check_smtp_send(host, user, password):
    msg_id = str(uuid.uuid4())[:8]
    subject = f"[smoke-test] {msg_id}"
    body = f"Mail server smoke test — {time.strftime('%Y-%m-%d %H:%M:%S')}"

    msg = MIMEText(body)
    msg["Subject"] = subject
    msg["From"] = user
    msg["To"] = user

    try:
        ctx = make_ssl_ctx()
        with smtplib.SMTP(host, 587, timeout=10) as smtp:
            smtp.ehlo()
            smtp.starttls(context=ctx)
            smtp.ehlo()
            smtp.login(user, password)
            smtp.sendmail(user, [user], msg.as_string())
        ok(f"SMTP AUTH + send to self")
        return subject
    except Exception as e:
        fail("SMTP AUTH + send to self", str(e))
        return None


# ── User-to-user send ───────────────────────────────────────────────────────
def check_user_to_user(host, sender, sender_pass, domain):
    """Create temp test mailbox, send, verify, cleanup."""
    msg_id = str(uuid.uuid4())[:8]
    test_user = f"smoketest-{msg_id}@{domain}"
    test_pass = "SmokeTest123!"
    subject = f"[u2u-test] {msg_id}"

    # Create temp mailbox in DB
    import subprocess as sp
    try:
        salt = "smoketest" + msg_id
        php_cmd = f"echo crypt('{test_pass}', '$6${salt}$');"
        h = sp.run(["php", "-r", php_cmd], capture_output=True, text=True).stdout.strip()
        sp.run([
            "mysql", "-u", "mailuser", "-pmaildbpass123", "mailserver", "-e",
            f"INSERT IGNORE INTO mailbox (username,password,name,maildir,quota,local_part,domain,created,modified,active) "
            f"VALUES ('{test_user}','{h}','SmokeTest','{domain}/smoketest-{msg_id}/',"
            f"1073741824,'smoketest-{msg_id}','{domain}',NOW(),NOW(),1);"
        ], capture_output=True, timeout=5)
    except Exception as e:
        fail("User-to-user (create temp mailbox)", str(e))
        return False

    # Send from sender to test user
    msg = MIMEText(f"User-to-user test from {sender} to {test_user}")
    msg["Subject"] = subject
    msg["From"] = sender
    msg["To"] = test_user
    try:
        ctx = make_ssl_ctx()
        with smtplib.SMTP(host, 587, timeout=10) as smtp:
            smtp.ehlo()
            smtp.starttls(context=ctx)
            smtp.ehlo()
            smtp.login(sender, sender_pass)
            smtp.sendmail(sender, [test_user], msg.as_string())
    except Exception as e:
        fail("User-to-user send", str(e))
        _cleanup_test_mailbox(test_user, domain)
        return False

    # Check test user received it via IMAP
    found = False
    for attempt in range(1, 11):
        time.sleep(3)
        try:
            with imaplib.IMAP4_SSL(host, 993, ssl_context=make_ssl_ctx()) as imap:
                imap.login(test_user, test_pass)
                imap.select("INBOX")
                _, data = imap.search(None, f'SUBJECT "{subject}"')
                if data[0]:
                    found = True
                    break
        except Exception:
            continue

    _cleanup_test_mailbox(test_user, domain)
    if found:
        ok(f"User-to-user: {sender.split('@')[0]} -> {test_user.split('@')[0]} (attempt {attempt})")
        return True
    fail("User-to-user send", f"not received at {test_user} after 30s")
    return False


def _cleanup_test_mailbox(test_user, domain):
    try:
        subprocess.run([
            "mysql", "-u", "mailuser", "-pmaildbpass123", "mailserver", "-e",
            f"DELETE FROM mailbox WHERE username='{test_user}';"
        ], capture_output=True, timeout=5)
    except Exception:
        pass


# ── Alias delivery ──────────────────────────────────────────────────────────
def check_alias(host, user, password, alias_addr):
    msg_id = str(uuid.uuid4())[:8]
    subject = f"[alias-test] {msg_id}"

    msg = MIMEText("Alias delivery test")
    msg["Subject"] = subject
    msg["From"] = user
    msg["To"] = alias_addr

    try:
        ctx = make_ssl_ctx()
        with smtplib.SMTP(host, 587, timeout=10) as smtp:
            smtp.ehlo()
            smtp.starttls(context=ctx)
            smtp.ehlo()
            smtp.login(user, password)
            smtp.sendmail(user, [alias_addr], msg.as_string())
    except Exception as e:
        fail(f"Alias delivery ({alias_addr})", str(e))
        return False

    # Alias should deliver to user's inbox
    for attempt in range(1, 11):
        time.sleep(3)
        try:
            with imaplib.IMAP4_SSL(host, 993, ssl_context=make_ssl_ctx()) as imap:
                imap.login(user, password)
                imap.select("INBOX")
                _, data = imap.search(None, f'SUBJECT "{subject}"')
                if data[0]:
                    ok(f"Alias: {alias_addr} -> {user} delivered (attempt {attempt})")
                    return True
        except Exception:
            continue

    fail(f"Alias delivery ({alias_addr})", f"not in {user} inbox after 30s")
    return False


# ── Reply cycle ──────────────────────────────────────────────────────────────
def check_reply(host, sender, sender_pass, recipient, recipient_pass):
    msg_id = str(uuid.uuid4())[:8]
    orig_subject = f"[reply-test] {msg_id}"
    reply_subject = f"Re: {orig_subject}"

    # Step 1: sender sends to recipient
    msg = MIMEText("Reply cycle test — original")
    msg["Subject"] = orig_subject
    msg["From"] = sender
    msg["To"] = recipient
    msg["Message-ID"] = f"<{msg_id}-orig@smoke>"

    try:
        ctx = make_ssl_ctx()
        with smtplib.SMTP(host, 587, timeout=10) as smtp:
            smtp.ehlo()
            smtp.starttls(context=ctx)
            smtp.ehlo()
            smtp.login(sender, sender_pass)
            smtp.sendmail(sender, [recipient], msg.as_string())
    except Exception as e:
        fail("Reply cycle (send original)", str(e))
        return False

    # Step 2: recipient replies
    reply = MIMEText("Reply cycle test — reply")
    reply["Subject"] = reply_subject
    reply["From"] = recipient
    reply["To"] = sender
    reply["In-Reply-To"] = msg["Message-ID"]

    try:
        with smtplib.SMTP(host, 587, timeout=10) as smtp:
            smtp.ehlo()
            smtp.starttls(context=ctx)
            smtp.ehlo()
            smtp.login(recipient, recipient_pass)
            smtp.sendmail(recipient, [sender], reply.as_string())
    except Exception as e:
        fail("Reply cycle (send reply)", str(e))
        return False

    # Step 3: check sender received reply
    for attempt in range(1, 11):
        time.sleep(3)
        try:
            with imaplib.IMAP4_SSL(host, 993, ssl_context=make_ssl_ctx()) as imap:
                imap.login(sender, sender_pass)
                imap.select("INBOX")
                _, data = imap.search(None, f'SUBJECT "{reply_subject}"')
                if data[0]:
                    ok(f"Reply cycle: original + reply delivered (attempt {attempt})")
                    return True
        except Exception:
            continue

    fail("Reply cycle", "reply not received by sender after 30s")
    return False


# ── Attachment ──────────────────────────────────────────────────────────────
def check_attachment(host, user, password):
    msg_id = str(uuid.uuid4())[:8]
    subject = f"[attach-test] {msg_id}"

    msg = MIMEMultipart()
    msg["Subject"] = subject
    msg["From"] = user
    msg["To"] = user
    msg.attach(MIMEText("Email with attachment"))

    # Add text file attachment
    attachment = MIMEBase("text", "plain")
    attachment.set_payload(b"Smoke test attachment content\n")
    encoders.encode_base64(attachment)
    attachment.add_header("Content-Disposition", "attachment", filename="smoke_test.txt")
    msg.attach(attachment)

    try:
        ctx = make_ssl_ctx()
        with smtplib.SMTP(host, 587, timeout=10) as smtp:
            smtp.ehlo()
            smtp.starttls(context=ctx)
            smtp.ehlo()
            smtp.login(user, password)
            smtp.sendmail(user, [user], msg.as_string())
    except Exception as e:
        fail("Attachment send", str(e))
        return False

    # Verify received with multipart body
    for attempt in range(1, 11):
        time.sleep(3)
        try:
            with imaplib.IMAP4_SSL(host, 993, ssl_context=make_ssl_ctx()) as imap:
                imap.login(user, password)
                imap.select("INBOX")
                _, data = imap.search(None, f'SUBJECT "{subject}"')
                if data[0]:
                    msg_nums = data[0].split()
                    _, msg_data = imap.fetch(msg_nums[-1], "(RFC822)")
                    raw = msg_data[0][1]
                    if b"smoke_test.txt" in raw and b"Content-Disposition" in raw:
                        ok(f"Attachment: sent + received with file (attempt {attempt})")
                        return True
        except Exception:
            continue

    fail("Attachment", "email with attachment not verified after 30s")
    return False


# ── IMAP login + find message ──────────────────────────────────────────────
def check_imap(host, user, password, search_subject, retries=10, delay=3):
    ctx = make_ssl_ctx()
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


# ── IMAP folder operations ─────────────────────────────────────────────────
def check_imap_folders(host, user, password):
    folder_name = f"SmokeTest-{str(uuid.uuid4())[:6]}"
    ctx = make_ssl_ctx()
    try:
        with imaplib.IMAP4_SSL(host, 993, ssl_context=ctx) as imap:
            imap.login(user, password)

            # Create folder
            status, _ = imap.create(folder_name)
            if status != "OK":
                fail("IMAP folders", f"CREATE {folder_name} failed")
                return False

            # List and verify
            status, folders = imap.list()
            found = any(folder_name in f.decode(errors="replace") for f in folders)
            if not found:
                fail("IMAP folders", f"{folder_name} not in LIST")
                imap.delete(folder_name)
                return False

            # Move a message: copy from INBOX then delete original
            imap.select("INBOX")
            _, data = imap.search(None, "ALL")
            if data[0]:
                msg_num = data[0].split()[0]
                imap.copy(msg_num, folder_name)
                imap.store(msg_num, "+FLAGS", "\\Deleted")
                imap.expunge()

            # Delete test folder
            imap.select("INBOX")
            imap.delete(folder_name)

        ok(f"IMAP folders: create / list / copy / delete")
        return True
    except Exception as e:
        fail("IMAP folders", str(e))
        return False


# ── POP3 login ──────────────────────────────────────────────────────────────
def check_pop3(host, user, password):
    try:
        ctx = make_ssl_ctx()
        conn = poplib.POP3_SSL(host, 995, context=ctx)
        conn.user(user)
        conn.pass_(password)
        count, size = conn.stat()
        conn.quit()
        ok(f"POP3 login ({count} messages, {size} bytes)")
        return True
    except Exception as e:
        fail("POP3 login", str(e))
        return False


# ── Sieve filter (file into folder) ────────────────────────────────────────
def check_sieve_filter(host, user, password):
    msg_id = str(uuid.uuid4())[:8]
    folder = f"sieve-test-{msg_id}"
    subject = f"[sieve-filter] {msg_id}"

    # 1) Create target folder via IMAP
    ctx = make_ssl_ctx()
    try:
        with imaplib.IMAP4_SSL(host, 993, ssl_context=ctx) as imap:
            imap.login(user, password)
            imap.create(folder)
    except Exception as e:
        fail("Sieve filter (create folder)", str(e))
        return False

    # 2) Upload sieve script that files by subject
    sieve_script = (
        f'require ["fileinto"];\n'
        f'if header :contains "Subject" "{subject}" {{\n'
        f'  fileinto "{folder}";\n'
        f'}}\n'
    )
    try:
        s = socket.create_connection((host, 4190), timeout=10)
        s.recv(4096)
        auth_str = f"\x00{user}\x00{password}"
        s.sendall(('AUTHENTICATE "PLAIN" "' + base64.b64encode(auth_str.encode()).decode() + '"\r\n').encode())
        s.recv(4096)
        put_cmd = f'PUTSCRIPT "smoke-filter" {{{len(sieve_script)}}}\r\n{sieve_script}\r\n'
        s.sendall(put_cmd.encode())
        resp = s.recv(4096).decode(errors="replace")
        if "OK" not in resp:
            fail("Sieve filter (PUTSCRIPT)", resp[:80])
            s.close()
            return False
        s.sendall(b'SETACTIVE "smoke-filter"\r\n')
        resp = s.recv(4096).decode(errors="replace")
        s.close()
        if "OK" not in resp:
            fail("Sieve filter (SETACTIVE)", resp[:80])
            return False
    except Exception as e:
        fail("Sieve filter (upload)", str(e))
        return False

    # 3) Send matching email
    msg = MIMEText("Sieve filter test body")
    msg["Subject"] = subject
    msg["From"] = user
    msg["To"] = user
    try:
        with smtplib.SMTP("127.0.0.1", 25, timeout=10) as smtp:
            smtp.ehlo()
            smtp.sendmail(user, [user], msg.as_string())
    except Exception as e:
        fail("Sieve filter (send)", str(e))
        _sieve_filter_cleanup(host, user, password, folder)
        return False

    # 4) Check message landed in target folder
    found = False
    for attempt in range(1, 11):
        time.sleep(3)
        try:
            with imaplib.IMAP4_SSL(host, 993, ssl_context=ctx) as imap:
                imap.login(user, password)
                status, _ = imap.select(folder)
                if status == "OK":
                    _, data = imap.search(None, "ALL")
                    if data[0]:
                        found = True
                        break
        except Exception:
            continue

    # 5) Cleanup
    _sieve_filter_cleanup(host, user, password, folder)

    if found:
        ok(f"Sieve filter: filed into '{folder}' (attempt {attempt})")
        return True
    fail("Sieve filter", f"message not found in '{folder}' after 30s")
    return False


def _sieve_filter_cleanup(host, user, password, folder):
    # Deactivate sieve script
    try:
        s = socket.create_connection((host, 4190), timeout=5)
        s.recv(4096)
        auth_str = f"\x00{user}\x00{password}"
        s.sendall(('AUTHENTICATE "PLAIN" "' + base64.b64encode(auth_str.encode()).decode() + '"\r\n').encode())
        s.recv(4096)
        s.sendall(b'SETACTIVE ""\r\n')
        s.recv(4096)
        s.sendall(b'DELETESCRIPT "smoke-filter"\r\n')
        s.recv(4096)
        s.sendall(b'LOGOUT\r\n')
        s.close()
    except Exception:
        pass
    # Delete test folder
    try:
        with imaplib.IMAP4_SSL(host, 993, ssl_context=make_ssl_ctx()) as imap:
            imap.login(user, password)
            imap.select("INBOX")
            imap.delete(folder)
    except Exception:
        pass


# ── Roundcube web login ────────────────────────────────────────────────────
def check_roundcube(host, user, password):
    try:
        ctx = make_ssl_ctx()
        conn = HTTPSConnection(host, 443, context=ctx, timeout=10)

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
        data = urlencode({"_token": token, "_user": user, "_pass": password,
                          "_task": "login", "_action": "login"})
        conn.request("POST", "/mail/?_task=login", body=data,
                      headers={"Content-Type": "application/x-www-form-urlencoded",
                               "Cookie": cookie_str})
        resp = conn.getresponse()

        for hdr in resp.getheaders():
            if hdr[0].lower() == "set-cookie":
                part = hdr[1].split(";")[0]
                if "=" in part:
                    k, v = part.split("=", 1)
                    cookies[k.strip()] = v.strip()
        cookie_str = "; ".join(f"{k}={v}" for k, v in cookies.items())

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
        ctx = make_ssl_ctx()
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
            ok("ManageSieve(4190) — banner received")
            return True
        fail("ManageSieve(4190)", f"unexpected banner: {banner[:80]}")
        return False
    except Exception as e:
        fail("ManageSieve(4190)", str(e))
        return False


# ── Vacation auto-reply ────────────────────────────────────────────────────
def check_vacation(host, user, password, domain):
    ctx = make_ssl_ctx()
    msg_id = str(uuid.uuid4())[:8]

    # 1) Upload vacation sieve script
    sieve_script = 'require ["vacation"];\nvacation\n  :subject "Out of Office (smoke test)"\n  "I am currently out of the office. This is an automated smoke test reply.";\n'
    try:
        s = socket.create_connection((host, 4190), timeout=10)
        banner = s.recv(4096).decode(errors="replace")
        if "OK" not in banner:
            fail("Vacation auto-reply", f"Sieve banner error: {banner[:80]}")
            return False
        auth_str = f"\x00{user}\x00{password}"
        s.sendall(('AUTHENTICATE "PLAIN" "' + base64.b64encode(auth_str.encode()).decode() + '"\r\n').encode())
        resp = s.recv(4096).decode(errors="replace")
        if "OK" not in resp:
            fail("Vacation auto-reply", f"Sieve AUTH failed: {resp[:80]}")
            s.close()
            return False
        put_cmd = f'PUTSCRIPT "smoke-vacation" {{{len(sieve_script)}}}\r\n{sieve_script}\r\n'
        s.sendall(put_cmd.encode())
        resp = s.recv(4096).decode(errors="replace")
        if "OK" not in resp:
            fail("Vacation auto-reply", f"Sieve PUTSCRIPT failed: {resp[:80]}")
            s.close()
            return False
        s.sendall(b'SETACTIVE "smoke-vacation"\r\n')
        resp = s.recv(4096).decode(errors="replace")
        if "OK" not in resp:
            fail("Vacation auto-reply", f"Sieve SETACTIVE failed: {resp[:80]}")
            s.close()
            return False
        s.close()
    except Exception as e:
        fail("Vacation auto-reply (sieve setup)", str(e))
        return False

    # 2) Send from unique address via localhost:25
    fake_sender = f"smoke-{msg_id}@{domain}"
    msg = MIMEText("Vacation auto-reply smoke test body")
    msg["Subject"] = f"[vacation-test] {msg_id}"
    msg["From"] = fake_sender
    msg["To"] = user
    try:
        with smtplib.SMTP("127.0.0.1", 25, timeout=10) as smtp:
            smtp.ehlo()
            smtp.sendmail(fake_sender, [user], msg.as_string())
    except Exception as e:
        fail("Vacation auto-reply (send trigger)", str(e))
        _vacation_cleanup(host, user, password)
        return False

    # 3) Check mail log
    found = False
    for attempt in range(1, 7):
        time.sleep(3)
        try:
            result = subprocess.run(
                ["grep", fake_sender, "/var/log/mail.log"],
                capture_output=True, text=True, timeout=5)
            if "vacation action" in result.stdout:
                found = True
                break
        except Exception:
            continue

    _vacation_cleanup(host, user, password)
    if found:
        ok(f"Vacation auto-reply fired (attempt {attempt})")
        return True
    fail("Vacation auto-reply", "no vacation action in mail.log after 18s")
    return False


def _vacation_cleanup(host, user, password):
    try:
        s = socket.create_connection((host, 4190), timeout=5)
        s.recv(4096)
        auth_str = f"\x00{user}\x00{password}"
        s.sendall(('AUTHENTICATE "PLAIN" "' + base64.b64encode(auth_str.encode()).decode() + '"\r\n').encode())
        s.recv(4096)
        s.sendall(b'SETACTIVE ""\r\n')
        s.recv(4096)
        s.sendall(b'DELETESCRIPT "smoke-vacation"\r\n')
        s.recv(4096)
        s.sendall(b'LOGOUT\r\n')
        s.close()
    except Exception:
        pass


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
        try:
            dkim = dns.resolver.resolve(f"default._domainkey.{domain}", "TXT")
            ok(f"DKIM record found ({len(dkim)} key(s))")
        except Exception:
            fail("DKIM record", f"no TXT at default._domainkey.{domain}")
    except Exception as e:
        skip(f"SPF/DKIM DNS ({e})")


# ── Main ────────────────────────────────────────────────────────────────────
def main():
    parser = argparse.ArgumentParser(description="Mail server smoke test")
    parser.add_argument("--host", default="10.211.55.11")
    parser.add_argument("--user", default="admin@example.com")
    parser.add_argument("--password", default="adminpass123")
    parser.add_argument("--domain", default="example.com")
    args = parser.parse_args()

    h, u, p, d = args.host, args.user, args.password, args.domain
    local = u.split("@")[0]
    # Second real mailbox for reply test (postmaster is alias to admin, use IMAP as admin)
    user2 = u  # reply test sends to self with different subject

    print(f"\n{BOLD}Mail Server Smoke Test — Full Email Lifecycle{RESET}")
    print(f"Host: {h}  User: {u}  Domain: {d}\n")

    # ── Network ──
    print(f"{BOLD}── TCP Connectivity ──{RESET}")
    check_tcp(h, 25, "SMTP")
    check_tcp(h, 587, "SMTP-Submit")
    check_tcp(h, 993, "IMAPS")
    check_tcp(h, 995, "POP3S")
    check_tcp(h, 443, "HTTPS")
    check_tcp(h, 4190, "ManageSieve")

    # ── SMTP ──
    print(f"\n{BOLD}── SMTP ──{RESET}")
    check_smtp_starttls(h)
    subject = check_smtp_send(h, u, p)

    # ── Full email cycle ──
    print(f"\n{BOLD}── Email Delivery ──{RESET}")
    if subject:
        check_imap(h, u, p, subject)
    else:
        fail("IMAP receive: skipped (send failed)")
    check_user_to_user(h, u, p, d)
    check_alias(h, u, p, f"webmaster@{d}")

    # ── Reply cycle (self-reply simulates 2 users) ──
    print(f"\n{BOLD}── Reply Cycle ──{RESET}")
    check_reply(h, u, p, u, p)

    # ── Attachments ──
    print(f"\n{BOLD}── Attachments ──{RESET}")
    check_attachment(h, u, p)

    # ── POP3 ──
    print(f"\n{BOLD}── POP3 ──{RESET}")
    check_pop3(h, u, p)

    # ── IMAP folders ──
    print(f"\n{BOLD}── IMAP Folders ──{RESET}")
    check_imap_folders(h, u, p)

    # ── Web ──
    print(f"\n{BOLD}── Web ──{RESET}")
    check_roundcube(h, u, p)
    check_postfixadmin(h)

    # ── Sieve ──
    print(f"\n{BOLD}── Sieve ──{RESET}")
    check_sieve(h)
    check_sieve_filter(h, u, p)

    # ── Vacation ──
    print(f"\n{BOLD}── Vacation ──{RESET}")
    check_vacation(h, u, p, d)

    # ── DNS ──
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
