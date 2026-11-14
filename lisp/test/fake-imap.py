#!/usr/bin/env python3
"""A tiny IMAP server for tests.  Not for real use.

    fake-imap.py LOGFILE [--user U --password P] [--no-xgmraw]

Listens on 127.0.0.1 on a free port and prints "PORT <n>" first.  Serves three
unread messages in INBOX (uids 1-3).  Every command received is appended to
LOGFILE, so a test can check that nothing writes (STORE, COPY, EXPUNGE ...).
"""
import socketserver
import sys

MESSAGES = {
    "1": ("Ann Lee <ann@example.com>", "=?UTF-8?B?w4RuZGVyZSBGcmFnZQ==?=",   # "Ändere Frage"
          "Mon, 16 Nov 2026 10:00:00 +0000", "<m1@example.com>"),
    "2": ("bob@example.com", "Lunch?", "Mon, 16 Nov 2026 11:00:00 +0000", "<m2@example.com>"),
    "3": ('"Carol, Q." <carol@example.com>', "Re: budget", "Mon, 16 Nov 2026 09:00:00 +0000",
          "<m3@example.com>"),
}

args = sys.argv[1:]
LOG = args.pop(0)
USER, PASSWORD, XGMRAW = "me", "secret", True
while args:
    a = args.pop(0)
    if a == "--user": USER = args.pop(0)
    elif a == "--password": PASSWORD = args.pop(0)
    elif a == "--no-xgmraw": XGMRAW = False


class Handler(socketserver.StreamRequestHandler):
    def reply(self, text):
        self.wfile.write(text.encode() + b"\r\n")

    def handle(self):
        self.reply("* OK fake imap ready")
        while True:
            line = self.rfile.readline().decode(errors="replace").rstrip("\r\n")
            if not line:
                return
            with open(LOG, "a") as f:
                # Log the command (never the credentials).
                f.write(("LOGIN" if " LOGIN " in line else line.partition(" ")[2]) + "\n")
            tag, _, rest = line.partition(" ")
            verb = rest.split(" ")[0].upper()
            if verb == "CAPABILITY":
                self.reply("* CAPABILITY IMAP4rev1"); self.reply(f"{tag} OK done")
            elif verb == "LOGIN":
                parts = rest.split(" ")
                user, pw = parts[1].strip('"'), parts[2].strip('"')
                if (user, pw) == (USER, PASSWORD):
                    self.reply(f"{tag} OK LOGIN completed")
                else:
                    self.reply(f"{tag} NO [AUTHENTICATIONFAILED] Invalid credentials")
            elif verb in ("SELECT", "EXAMINE"):
                self.reply("* 3 EXISTS")
                self.reply(f"{tag} OK [{'READ-WRITE' if verb == 'SELECT' else 'READ-ONLY'}] done")
            elif verb == "UID" and rest.upper().startswith("UID SEARCH"):
                if "X-GM-RAW" in rest.upper() and not XGMRAW:
                    self.reply(f"{tag} BAD unknown search key")
                else:
                    self.reply("* SEARCH 1 2 3"); self.reply(f"{tag} OK done")
            elif verb == "UID" and rest.upper().startswith("UID FETCH"):
                uid = rest.split(" ")[2]
                frm, subj, date, mid = MESSAGES[uid]
                hdr = f"From: {frm}\r\nSubject: {subj}\r\nDate: {date}\r\nMessage-ID: {mid}\r\n\r\n"
                self.wfile.write((f"* {uid} FETCH (UID {uid} BODY[HEADER.FIELDS (FROM SUBJECT DATE "
                                  f"MESSAGE-ID)] {{{len(hdr)}}}\r\n{hdr})\r\n").encode())
                self.reply(f"{tag} OK done")
            elif verb == "LOGOUT":
                self.reply("* BYE"); self.reply(f"{tag} OK done"); return
            else:
                self.reply(f"{tag} BAD unsupported")


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


with Server(("127.0.0.1", 0), Handler) as srv:
    print("PORT", srv.server_address[1], flush=True)
    srv.serve_forever()
