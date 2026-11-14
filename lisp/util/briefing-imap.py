#!/usr/bin/env python3
"""Newest unread mail of one IMAP account, as one JSON line.  Read-only.

Used by briefing.el.  Settings arrive as JSON on stdin (so nothing secret
appears in a process listing):

    {"host": "imap.gmail.com", "port": 993, "user": "me@example.com",
     "pass_entry": "email/personal", "limit": 8, "ssl": true}

The password comes from `pass show PASS_ENTRY` (first line), run here, so it
never passes through Emacs.  Alternatively give "password" directly.

Output (one line):

    BRIEFING-JSON:{"unseen": 12, "messages": [{"uid": "5", "from": "Ann <a@x>",
                   "subject": "...", "date": 1794600000, "msgid": "<..>"}, ...]}

On failure: BRIEFING-ERROR:<message> and exit status 2.

The mailbox is opened read-only and bodies are fetched with BODY.PEEK, so
nothing is marked as read.  For Gmail the search is "unread, in the inbox,
Primary tab", because plain UNSEEN also counts Promotions and Social.
"""
import email.header
import email.utils
import imaplib
import json
import re
import socket
import subprocess
import sys


def decode(value):
    if not value:
        return ""
    parts = []
    for text, charset in email.header.decode_header(value):
        if isinstance(text, bytes):
            try:
                text = text.decode(charset or "utf-8", "replace")
            except LookupError:
                text = text.decode("utf-8", "replace")
        parts.append(text)
    return re.sub(r"\s+", " ", "".join(parts)).strip()


def sender(value):
    name, addr = email.utils.parseaddr(decode(value))
    return name or addr


def epoch(value):
    try:
        return int(email.utils.parsedate_to_datetime(value).timestamp())
    except (TypeError, ValueError):
        return 0


def search_unread(conn, host):
    """UIDs of unread inbox mail (Primary tab only on Gmail)."""
    if host.endswith("gmail.com") or host.endswith("googlemail.com"):
        typ, data = conn.uid("SEARCH", None, "X-GM-RAW", '"is:unread in:inbox category:primary"')
        if typ == "OK":
            return data[0].split()
    typ, data = conn.uid("SEARCH", None, "UNSEEN")
    if typ != "OK":
        raise imaplib.IMAP4.error("search failed")
    return data[0].split()


def fetch_headers(conn, uids):
    messages = []
    for uid in uids:
        typ, data = conn.uid(
            "FETCH", uid, "(BODY.PEEK[HEADER.FIELDS (FROM SUBJECT DATE MESSAGE-ID)])")
        if typ != "OK" or not data or not isinstance(data[0], tuple):
            continue
        msg = email.message_from_bytes(data[0][1])
        messages.append({
            "uid": uid.decode(),
            "from": sender(msg.get("From")),
            "subject": decode(msg.get("Subject")) or "(no subject)",
            "date": epoch(msg.get("Date")),
            "msgid": (msg.get("Message-ID") or "").strip(),
        })
    return messages


def password_from(cfg):
    """The account password: `pass show ENTRY` (first line), else cfg["password"]."""
    entry = cfg.get("pass_entry")
    if not entry:
        if cfg.get("password"):
            return cfg["password"]
        raise imaplib.IMAP4.error("no password configured")
    try:
        r = subprocess.run(["pass", "show", entry], capture_output=True, text=True, timeout=45)
    except FileNotFoundError:
        raise imaplib.IMAP4.error("`pass` is not installed")
    except subprocess.TimeoutExpired:
        raise imaplib.IMAP4.error("`pass show %s` timed out (passphrase prompt?)" % entry)
    first = r.stdout.split("\n")[0] if r.returncode == 0 else ""
    if not first:
        raise imaplib.IMAP4.error("could not read %s from pass" % entry)
    return first


def main():
    cfg = json.load(sys.stdin)
    host = cfg["host"]
    port = int(cfg.get("port") or 993)
    limit = 8 if cfg.get("limit") is None else int(cfg["limit"])   # 0 means "count only"
    socket.setdefaulttimeout(30)
    password = password_from(cfg)   # before connecting: a missing entry should fail fast
    cls = imaplib.IMAP4_SSL if cfg.get("ssl", True) else imaplib.IMAP4
    conn = cls(host, port)
    try:
        conn.login(cfg["user"], password)
        typ, _ = conn.select("INBOX", readonly=True)
        if typ != "OK":
            raise imaplib.IMAP4.error("cannot open INBOX")
        uids = search_unread(conn, host)
        newest = uids[-limit:] if limit > 0 else []
        messages = fetch_headers(conn, newest)
        messages.sort(key=lambda m: m["date"], reverse=True)
        print("BRIEFING-JSON:" + json.dumps({"unseen": len(uids), "messages": messages}))
    finally:
        try:
            conn.logout()
        except Exception:
            pass


if __name__ == "__main__":
    try:
        main()
    except imaplib.IMAP4.error as e:
        # imaplib errors carry the server's words, e.g. "[AUTHENTICATIONFAILED] ..."
        print("BRIEFING-ERROR:" + re.sub(r"\s+", " ", str(e))[:200])
        sys.exit(2)
    except Exception as e:  # network, DNS, timeout, bad input
        print("BRIEFING-ERROR:%s: %s" % (type(e).__name__, str(e)[:160]))
        sys.exit(2)
