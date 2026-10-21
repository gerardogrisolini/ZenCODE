#!/usr/bin/env python3
"""Runs `zen` in a pty, relays the terminal transparently, and drives the
shared-chat part of the demo by watching zen's own output:

1. first shared-chat message  -> open the chat reader (Ctrl+Y)
2. second message (or timeout) -> show it, type an operator reply, send it
3. close the reader (Ctrl+Y) while the agents keep working
4. end of turn                 -> hold the final screen, then /exit
"""
import os, pty, re, select, sys, termios, time, tty, fcntl, struct

LOG = open(os.environ.get("DIRECTOR_LOG", "/tmp/zen-demo-rec/director.log"), "w")
REPLY = os.environ.get("DIRECTOR_REPLY", "@all Thanks, the API looks good. Go ahead and finish.")
ANSI = re.compile(rb"\x1b\[[0-9;?>=]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b.")

def log(msg):
    LOG.write(f"{time.monotonic() - T0:7.2f} {msg}\n"); LOG.flush()

T0 = time.monotonic()
pid, fd = pty.fork()
if pid == 0:
    os.execvp("zen", ["zen", *sys.argv[1:]])

try:
    size = fcntl.ioctl(0, termios.TIOCGWINSZ, b"\0" * 8)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, size)
except OSError:
    pass
saved = termios.tcgetattr(0)
tty.setraw(0)

queue = []          # (due_time, bytes)
def send(data, delay=0.0):
    last = max([t for t, _ in queue], default=time.monotonic())
    queue.append((max(last, time.monotonic()) + delay, data))
def type_text(text, cps_delay=0.045):
    for ch in text:
        send(ch.encode(), cps_delay)

text = ""           # stripped output tail
state = "await-first"
deadline = None
try:
    while True:
        now = time.monotonic()
        timeout = 0.05
        r, _, _ = select.select([0, fd], [], [], timeout)
        if fd in r:
            try:
                data = os.read(fd, 65536)
            except OSError:
                break
            if not data:
                break
            os.write(1, data)
            text = (text + ANSI.sub(b"", data).decode("utf-8", "replace"))[-20000:]
        if 0 in r:
            data = os.read(0, 4096)
            if data:
                os.write(fd, data)
        while queue and queue[0][0] <= time.monotonic():
            os.write(fd, queue.pop(0)[1])

        if state == "await-first" and re.search(r"Chat\s*·\s*1 message", text):
            log("first message -> open reader")
            send(b"\x19", 1.2)
            state, deadline, text = "await-second", time.monotonic() + 30, ""
        elif state == "await-second" and (
            re.search(r"Chat\s*·\s*(2 messages|\d+/2)", text) or time.monotonic() > deadline
        ):
            log("second message (or timeout) -> show it and reply")
            send(b"\x1b[C", 4.0)          # Right: next/latest message
            send(b"", 5.0)
            type_text(REPLY)
            send(b"\r", 1.0)
            send(b"\x1b[F", 2.0)          # End: jump to the operator's message
            send(b"\x1b[F", 3.0)          # ...and to any reply that followed
            send(b"\x19", 4.0)            # close the reader
            state, text = "await-end", ""
        elif state == "await-end" and not queue and "Use /undo to revert" in text:
            log("turn finished -> hold, then exit")
            send(b"/exit\r", 7.0)
            state = "exiting"
finally:
    termios.tcsetattr(0, termios.TCSADRAIN, saved)
    log("done")
    os.waitpid(pid, 0)
