# PadCode terminal helper for macOS/Linux, run on the desktop. Stdlib only, 3.6+.
#
#   python3 -c <this> COLS ROWS
#       a shell on a pty, piped to stdin/stdout; ends when stdin closes.
#   python3 -c <this> attach ID COLS ROWS OFFSET
#       a *persistent* shell: a small daemon owns the pty and keeps the shell
#       running (and the last RING bytes of output) across disconnects; this
#       process is only a relay, so closing it detaches without killing the
#       shell. Reattaching with OFFSET = bytes already received replays only
#       what was missed. The relay first prints  ESC ] 7778 ; START BEL  (the
#       absolute offset of the bytes that follow); on shell exit the daemon
#       sends  ESC ] 7779 ; CODE BEL. A replay that starts at the ring's start
#       first restores the terminal modes set by output that fell out of it
#       (alternate screen, mouse tracking…), or full-screen apps like Claude
#       Code come back as plain scrolling text.
#
# In-band on stdin:  ESC ] 7777 ; COLS ; ROWS BEL  resizes;  ESC ] 7777 ; kill BEL
# ends the shell. Both are stripped before reaching the shell.
import fcntl, os, pwd, re, select, signal, socket, struct, sys, termios, time

FRAME = re.compile(rb"\x1b\]7777;(\d+);(\d+)\x07|\x1b\]7777;kill\x07")
PREFIX = b"\x1b]7777;"
HOLD = 0.05      # seconds a possible partial frame may wait for its tail
RING = 512 * 1024
IDLE_LIMIT = 24 * 3600  # a detached session nobody reattaches to is ended
# DEC private modes that persist: cursor keys, wrap, cursor shown, alternate
# screens, mouse tracking and encodings, focus events, bracketed paste.
MODE = re.compile(rb"\x1b\[\?([\d;]+)([hl])")
KEPT = {1, 7, 25, 47, 1000, 1002, 1003, 1004, 1005, 1006, 1015, 1047, 1049, 2004}


def split_frames(buf):
    """Returns (data for the shell, [(cols, rows) or 'kill'...], undecided tail)."""
    out, events, pos = [], [], 0
    for m in FRAME.finditer(buf):
        out.append(buf[pos:m.start()])
        events.append((int(m.group(1)), int(m.group(2))) if m.group(1) else "kill")
        pos = m.end()
    rest = buf[pos:]
    # Keep back a tail that could still become a frame. A lone trailing ESC is
    # passed straight through: it's almost always the Esc key (vim), and frames
    # are written whole, so holding it would only add latency.
    i = rest.rfind(b"\x1b")
    if i >= 0 and len(rest) - i >= 2:
        tail = rest[i:]
        if PREFIX.startswith(tail) or (tail.startswith(PREFIX) and re.match(rb"^[\dkil;]*$", tail[len(PREFIX):])):
            out.append(rest[:i])
            return b"".join(out), events, tail
    out.append(rest)
    return b"".join(out), events, b""


def track(modes, data):
    """Applies the mode changes in `data` to `modes` ({mode: on})."""
    # ponytail: a sequence split across a trim boundary is missed; harmless,
    # an app sets these once and the next one fixes it.
    for m in MODE.finditer(data):
        for p in m.group(1).split(b";"):
            if p.isdigit() and int(p) in KEPT:
                modes[int(p)] = m.group(2) == b"h"


def restore(modes):
    on = b";".join(b"%d" % k for k in sorted(modes) if modes[k])
    off = b";".join(b"%d" % k for k in sorted(modes) if not modes[k])
    return (b"\x1b[?%sl" % off if off else b"") + (b"\x1b[?%sh" % on if on else b"")


def replay(start, buf, have):
    """What to send a client that already has `have` bytes: (start offset, data, reset)."""
    total = start + len(buf)
    if start <= have <= total:
        return have, bytes(buf[have - start:]), False
    # Too old (fell out of the ring) or from another life of the session.
    return start, bytes(buf), have > 0


def set_size(fd, cols, rows):
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))


def write_all(fd, data):
    while data:
        data = data[os.write(fd, data):]


def start_shell(cols, rows):
    shell = os.environ.get("SHELL") or pwd.getpwuid(os.getuid()).pw_shell or "/bin/sh"
    master, slave = os.openpty()
    set_size(slave, cols, rows)
    pid = os.fork()
    if pid == 0:
        os.close(master)
        os.setsid()
        if hasattr(termios, "TIOCSCTTY"):
            fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
        else:
            os.close(os.open(os.ttyname(slave), os.O_RDWR))
        for fd in (0, 1, 2):
            os.dup2(slave, fd)
        if slave > 2:
            os.close(slave)
        os.environ.setdefault("TERM", "xterm-256color")
        os.execv(shell, ["-" + os.path.basename(shell)])  # leading "-" = login shell
    os.close(slave)
    return pid, master


def exit_code(pid):
    _, status = os.waitpid(pid, 0)
    return os.WEXITSTATUS(status) if os.WIFEXITED(status) else 128 + os.WTERMSIG(status)


def handle_events(events, pid, master):
    for e in events:
        if e == "kill":
            os.killpg(pid, signal.SIGHUP)
        else:
            set_size(master, *e)  # kernel delivers SIGWINCH to the shell


# ---- one-shot shell (no persistence) ----

def direct(cols, rows):
    pid, master = start_shell(cols, rows)
    pending = b""
    while True:
        try:
            ready, _, _ = select.select([0, master], [], [], HOLD if pending else None)
        except InterruptedError:
            continue
        if not ready and pending:  # the tail never completed: it was typed input
            write_all(master, pending)
            pending = b""
        if master in ready:
            try:
                data = os.read(master, 65536)
            except OSError:  # EIO: shell exited (Linux)
                data = b""
            if not data:
                break
            write_all(1, data)
        if 0 in ready:
            data = os.read(0, 65536)
            if not data:  # client closed the terminal
                os.killpg(pid, signal.SIGHUP)
                break
            data, events, pending = split_frames(pending + data)
            handle_events(events, pid, master)
            if data:
                write_all(master, data)
    return exit_code(pid)


# ---- persistent sessions ----

def sock_path(sid):
    d = os.path.join(os.path.expanduser("~"), ".padcode", "term")
    os.makedirs(d, mode=0o700, exist_ok=True)
    os.chmod(d, 0o700)
    return os.path.join(d, re.sub(r"[^A-Za-z0-9_-]", "", sid)[:40] + ".sock")


def daemon(path, cols, rows):
    pid, master = start_shell(cols, rows)
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass
    lst = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    old = os.umask(0o077)
    lst.bind(path)
    os.umask(old)
    lst.listen(2)
    buf, start, head = bytearray(), 0, {}  # head: modes in force at `start`
    client, pending, detached_at = None, b"", time.time()
    while True:
        rl = [master, lst] + ([client] if client else [])
        try:
            ready, _, _ = select.select(rl, [], [], HOLD if pending else 60)
        except InterruptedError:
            continue
        if not ready:
            if pending:
                write_all(master, pending)
                pending = b""
            if client is None and time.time() - detached_at > IDLE_LIMIT:
                os.killpg(pid, signal.SIGHUP)
            continue
        if master in ready:
            try:
                data = os.read(master, 65536)
            except OSError:
                data = b""
            if not data:
                break
            buf += data
            if len(buf) > RING:
                drop = len(buf) - RING
                track(head, bytes(buf[:drop]))
                del buf[:drop]
                start += drop
            if client:
                try:
                    client.sendall(data)
                except OSError:
                    client.close()
                    client, detached_at = None, time.time()
        if lst in ready:
            c, _ = lst.accept()
            c.settimeout(5)
            try:
                line = b""
                while not line.endswith(b"\n") and len(line) < 100:
                    chunk = c.recv(1)
                    if not chunk:
                        break
                    line += chunk
                _, have, ccols, crows = line.split()
                have, ccols, crows = int(have), int(ccols), int(crows)
            except (OSError, ValueError):
                c.close()
                continue
            c.settimeout(None)
            if client:  # a newer connection replaces the old one
                client.close()
            client, pending = c, b""
            off, data, reset = replay(start, buf, have)
            # A client that's missing history gets the modes as of `start`. The
            # offset is moved back by their length so its byte count stays exact.
            modes = restore(head) if off != have else b""
            off = max(0, off - len(modes))
            try:
                client.sendall(b"\x1b]7778;%d\x07" % off + (b"\x1bc" if reset else b"") + modes + data)
            except OSError:
                client = None
            # Nudge full-screen apps (vim, htop) to redraw for this view.
            set_size(master, ccols, max(crows - 1, 1))
            set_size(master, ccols, crows)
            continue
        if client and client in ready:
            try:
                data = client.recv(65536)
            except OSError:
                data = b""
            if not data:
                client.close()
                client, pending, detached_at = None, b"", time.time()
                continue
            data, events, pending = split_frames(pending + data)
            handle_events(events, pid, master)
            if data:
                write_all(master, data)
    code = exit_code(pid)
    if client:
        try:
            client.sendall(b"\x1b]7779;%d\x07" % code)
            client.close()
        except OSError:
            pass
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass


def spawn_daemon(path, cols, rows):
    if os.fork() == 0:
        os.setsid()
        if os.fork() == 0:
            null = os.open(os.devnull, os.O_RDWR)
            for fd in (0, 1, 2):
                os.dup2(null, fd)
            try:
                daemon(path, cols, rows)
            finally:
                os._exit(0)
        os._exit(0)
    os.wait()


def attach(sid, cols, rows, have):
    path = sock_path(sid)
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        s.connect(path)
    except OSError:
        spawn_daemon(path, cols, rows)
        for _ in range(100):
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            try:
                s.connect(path)
                break
            except OSError:
                time.sleep(0.03)
        else:
            sys.stderr.write("padcode: could not start terminal session\n")
            return 1
    s.sendall(b"ATTACH %d %d %d\n" % (have, cols, rows))
    tail, killing = b"", False
    while True:
        try:
            ready, _, _ = select.select([0, s], [], [])
        except InterruptedError:
            continue
        if s in ready:
            data = s.recv(65536)
            if not data:
                m = re.search(rb"\x1b\]7779;(\d+)\x07", tail)
                return int(m.group(1)) if m else 0
            tail = (tail + data)[-32:]
            write_all(1, data)
        if 0 in ready:
            data = os.read(0, 65536)
            if not data:  # PadCode went away: detach, the shell keeps running
                if killing:  # but a kill must land first: wait for the shell to end
                    s.settimeout(3)
                    try:
                        while s.recv(65536):
                            pass
                    except OSError:
                        pass
                return 0
            killing = killing or b"\x1b]7777;kill\x07" in data
            s.sendall(data)


def selftest():
    assert split_frames(b"ls\r") == (b"ls\r", [], b"")
    assert split_frames(b"a\x1b]7777;120;40\x07b") == (b"ab", [(120, 40)], b"")
    assert split_frames(b"\x1b]7777;1;2\x07\x1b]7777;3;4\x07") == (b"", [(1, 2), (3, 4)], b"")
    assert split_frames(b"x\x1b]7777;kill\x07") == (b"x", ["kill"], b"")
    assert split_frames(b"x\x1b]77") == (b"x", [], b"\x1b]77")
    assert split_frames(b"x\x1b]7777;12") == (b"x", [], b"\x1b]7777;12")
    assert split_frames(b"x\x1b]7777;ki") == (b"x", [], b"\x1b]7777;ki")
    assert split_frames(b"\x1b") == (b"\x1b", [], b"")  # Esc key: no delay
    assert split_frames(b"\x1b]") == (b"", [], b"\x1b]")  # could be a frame: held
    assert split_frames(b"\x1b[A") == (b"\x1b[A", [], b"")  # arrow key passes through
    data, sizes, tail = split_frames(b"q\x1b]77")
    assert split_frames(tail + b"77;80;24\x07z") == (b"z", [(80, 24)], b"")
    # replay: caught up, partially behind, fell out of the ring, other session life
    assert replay(100, b"abcdef", 106) == (106, b"", False)
    assert replay(100, b"abcdef", 103) == (103, b"def", False)
    assert replay(100, b"abcdef", 50) == (100, b"abcdef", True)
    assert replay(0, b"abc", 0) == (0, b"abc", False)
    assert replay(0, b"abc", 999) == (0, b"abc", True)
    # modes that scrolled out of the ring come back before the replay
    m = {}
    track(m, b"x\x1b[?1049h\x1b[?1000;1006h\x1b[?2004h\x1b[?2026h\x1b[?25l")
    assert m == {1049: True, 1000: True, 1006: True, 2004: True, 25: False}
    track(m, b"\x1b[?2004l")
    assert restore(m) == b"\x1b[?25;2004l\x1b[?1000;1006;1049h"
    assert restore({}) == b""
    print("pty_unix selftest ok")


if __name__ == "__main__":
    a = sys.argv[1:]
    if a == ["--selftest"]:
        selftest()
    elif a and a[0] == "attach":
        sys.exit(attach(a[1], int(a[2]), int(a[3]), int(a[4])))
    else:
        sys.exit(direct(int(a[0]), int(a[1])))
