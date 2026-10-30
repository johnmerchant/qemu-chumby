# SPDX-License-Identifier: GPL-2.0-or-later
"""chumby_machine: runs the chumby-classic machine headless, for scripts
and tests, and drives it. Python 3.9 or later, standard library only.

A machine lives in a directory of its own (its state directory): QEMU's
process, its QMP socket and console socket, and the console's log. Every
operation opens the directory afresh, so a machine started by one process
is driven from any other (the `chumby-machine` command line is one).

    m = Machine("/tmp/m1")
    m.start(kernel="zImage", nand="nand.img", stick="stick.img", fast=True)
    m.wait_log(r"login:", 120)
    m.tap(160, 120)
    m.shot("screen.png")
    m.stop()

The machine never has a network: QEMU always runs with -nic none, and
options that would give it one are refused.

Besides the machine, the images a run needs and a few that it makes:
`mkfat` (a stick image of a directory), and `jffs2` and `nand_with`
(a NAND image with a partition's contents replaced, such as the settings
partition from a directory).
"""
import json
import os
import re
import shutil
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import time
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
MACHINE = "chumby-classic"
W, H = 320, 240

# Files in a machine's directory. QEMU runs there and is given the
# sockets' relative paths: a Unix socket's path is limited to about 100
# bytes, a state directory's isn't.
PID, QMP_SOCK, CON_SOCK, LOG, QEMU_LOG, CONFIG = (
    "qemu.pid", "qmp.sock", "console.sock", "console.log", "qemu.log", "machine.json")

# QEMU options that would give the guest a network.
NETWORK_OPTIONS = ("-netdev", "-net", "-nic")


class Error(Exception):
    """A failure to report to the person running the machine."""


def find_qemu(given=None):
    """qemu-system-arm with the machine: GIVEN, $QEMU, this checkout's
    build/obj/, else one on PATH that has the machine."""
    for q in (given, os.environ.get("QEMU"), os.path.join(HERE, "build", "obj", "qemu-system-arm")):
        if q and os.access(q, os.X_OK):
            return q
    q = shutil.which("qemu-system-arm")
    if q:
        r = subprocess.run([q, "-machine", "help"], capture_output=True, text=True)
        if re.search(rf"^{MACHINE}\s", r.stdout, re.M):
            return q
    raise Error(f"no qemu-system-arm with the {MACHINE} machine (./build, $QEMU or --qemu)")


# QMP.


class QMP:
    """One QMP connection: commands and their replies; events between them
    are kept in `events`. A machine's QMP socket serves one client at a
    time; a second waits until the first has gone."""

    def __init__(self, path, timeout=30):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(timeout)
        connect(self.sock, path)
        self.buf = b""
        self.events = []
        self.serial = 0
        self.message()  # the greeting
        self.cmd("qmp_capabilities")

    def close(self):
        self.sock.close()

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()

    def message(self):
        while b"\n" not in self.buf:
            got = self.sock.recv(65536)
            if not got:
                raise ConnectionError("the machine closed its QMP connection")
            self.buf += got
        line, self.buf = self.buf.split(b"\n", 1)
        return json.loads(line)

    def send(self, msg):
        """Sends a command and returns its reply's `return`. Each command
        carries an `id`, which QEMU echoes in its reply: a reply with
        another id, or none, answers something else (one left over from an
        earlier client, say) and is passed over."""
        self.serial += 1
        msg = dict(msg, id=f"chumby-machine-{self.serial}")
        self.sock.sendall(json.dumps(msg).encode() + b"\n")
        while True:
            r = self.message()
            if "event" in r:
                self.events.append(r)
            elif r.get("id") != msg["id"]:
                continue
            elif "error" in r:
                raise Error(f"{msg.get('execute')}: {r['error'].get('desc', r['error'])}")
            else:
                return r.get("return")

    def cmd(self, name, **args):
        msg = {"execute": name}
        if args:
            msg["arguments"] = args
        return self.send(msg)

    def hmp(self, line):
        """A human monitor command; its output, a string."""
        out = self.cmd("human-monitor-command", **{"command-line": line})
        if not isinstance(out, str):
            raise Error(f"human-monitor-command {line!r}: not a string: {out!r}")
        return out

    def qom_set(self, prop, value, path="/machine"):
        return self.cmd("qom-set", path=path, property=prop, value=value)

    def qom_get(self, prop, path="/machine"):
        return self.cmd("qom-get", path=path, property=prop)


def connect(sock, path):
    """Connects to a Unix socket whose path may be too long for one: from
    its own directory, by its name."""
    d, name = os.path.split(path)
    here = os.open(".", os.O_RDONLY)
    try:
        os.chdir(d or ".")
        sock.connect(name)
    finally:
        os.fchdir(here)
        os.close(here)


# The screen.


def axis(pixel, span):
    """A screen pixel's centre on QEMU's absolute axis (0-32767)."""
    return min(32767, (2 * pixel + 1) * 32767 // (2 * span))


def pen_events(down, x=None, y=None):
    ev = []
    if x is not None:
        ev += [{"type": "abs", "data": {"axis": "x", "value": axis(x, W)}},
               {"type": "abs", "data": {"axis": "y", "value": axis(y, H)}}]
    ev.append({"type": "btn", "data": {"button": "left", "down": down}})
    return ev


def ppm_rgb(ppm):
    """A binary PPM of the screen: its 8-bit RGB pixels."""
    m = re.match(rb"P6\s+(\d+)\s+(\d+)\s+(\d+)\s", ppm)
    if not m or (int(m.group(1)), int(m.group(2))) != (W, H) or m.group(3) != b"255":
        raise Error(f"not a {W}x{H} 8-bit PPM")
    return ppm[m.end():m.end() + W * H * 3]


def rgb_to_rgb565(rgb):
    """8-bit RGB as RGB565 values, a framebuffer's pixels."""
    return [(rgb[i] >> 3) << 11 | (rgb[i + 1] >> 2) << 5 | rgb[i + 2] >> 3 for i in range(0, len(rgb), 3)]


def png_rgb(data):
    """A PNG's 8-bit RGB pixels and size: 8-bit RGB or RGBA, not
    interlaced, as screendump and most tools write them."""
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise Error("not a PNG")
    pos, idat, w = 8, b"", None
    while pos < len(data):
        n, kind = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + n]
        pos += 12 + n
        if kind == b"IHDR":
            w, h, depth, colour, _, _, interlace = struct.unpack(">IIBBBBB", body)
            if depth != 8 or colour not in (2, 6) or interlace:
                raise Error("only 8-bit RGB or RGBA PNGs, not interlaced")
            bpp = 3 if colour == 2 else 4
        elif kind == b"IDAT":
            idat += body
        elif kind == b"IEND":
            break
    if w is None:
        raise Error("a PNG without IHDR")
    raw, stride = zlib.decompress(idat), w * bpp
    out, prev = bytearray(), bytearray(stride)
    for y in range(h):
        f, row = raw[y * (stride + 1)], bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for i in range(stride):
            a = row[i - bpp] if i >= bpp else 0
            b, c = prev[i], prev[i - bpp] if i >= bpp else 0
            if f == 1:
                row[i] = (row[i] + a) & 0xFF
            elif f == 2:
                row[i] = (row[i] + b) & 0xFF
            elif f == 3:
                row[i] = (row[i] + (a + b) // 2) & 0xFF
            elif f == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                row[i] = (row[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 0xFF
        prev = row
        if bpp == 4:
            row = bytearray(v for i, v in enumerate(row) if i % 4 != 3)
        out += row
    return bytes(out), w, h


def picture(path):
    """A picture of the screen to compare it with, as RGB565 values: a PNG,
    or a raw 320x240 RGB565 framebuffer dump (153600 bytes, little-endian)."""
    with open(path, "rb") as f:
        data = f.read()
    if data[:8] == b"\x89PNG\r\n\x1a\n":
        rgb, w, h = png_rgb(data)
        if (w, h) != (W, H):
            raise Error(f"{path}: {w}x{h}, not {W}x{H}")
        return rgb_to_rgb565(rgb)
    if len(data) != W * H * 2:
        raise Error(f"{path}: neither a PNG nor {W * H * 2} bytes of RGB565")
    return list(memoryview(data).cast("H"))


def masked(masks):
    """The pixel indexes outside the masks (X, Y, W, H rectangles)."""
    hidden = set()
    for x, y, w, h in masks:
        for row in range(max(0, y), min(H, y + h)):
            hidden.update(range(row * W + max(0, x), row * W + min(W, x + w)))
    return [i for i in range(W * H) if i not in hidden]


# The machine.


class Machine:
    def __init__(self, path):
        self.path = os.path.abspath(path)

    def at(self, name):
        return os.path.join(self.path, name)

    def read(self, name, default=None):
        try:
            with open(self.at(name)) as f:
                return f.read()
        except FileNotFoundError:
            return default

    def config(self):
        return json.loads(self.read(CONFIG) or "{}")

    def pid(self):
        """QEMU's process ID while it runs, else None."""
        try:
            pid = int(self.read(PID, "").strip())
            os.kill(pid, 0)
        except (ValueError, ProcessLookupError):
            return None
        except PermissionError:
            pass
        # A process that has exited but not been reaped (when it is ours).
        try:
            if os.waitpid(pid, os.WNOHANG)[0] == pid:
                return None
        except ChildProcessError:
            pass
        return pid

    def running(self):
        return self.pid() is not None

    def qmp(self, timeout=30):
        if not self.running():
            raise Error(f"the machine isn't running ({self.path})")
        return QMP(self.at(QMP_SOCK), timeout)

    def command_line(self, qemu, kernel, nand=None, nand_write=False, initrd=None, append=None,
                     stick=None, fast=False, props=None, extra=()):
        for a in extra:
            if a.split("=")[0] in NETWORK_OPTIONS and a != "-nic":
                raise Error(f"{a} isn't allowed: the emulated Chumby has no network")
        for i, a in enumerate(extra):
            if a in NETWORK_OPTIONS:
                raise Error(f"{a} {extra[i + 1] if i + 1 < len(extra) else ''} isn't allowed: "
                            "the emulated Chumby has no network")
        m = MACHINE + "".join(f",{k}={v}" for k, v in (props or {}).items())
        argv = [qemu, "-M", m, "-kernel", os.path.abspath(kernel), "-nic", "none",
                "-display", "none", "-monitor", "none",
                "-qmp", f"unix:{QMP_SOCK},server=on,wait=off",
                "-chardev", f"socket,id=con,path={CON_SOCK},server=on,wait=off,logfile={LOG},logappend=on",
                "-serial", "chardev:con"]
        if initrd:
            argv += ["-initrd", os.path.abspath(initrd)]
        if append is not None:
            argv += ["-append", append]
        if nand:
            argv += ["-drive", f"if=mtd,file={os.path.abspath(nand)},format=raw"
                     + ("" if nand_write else ",snapshot=on")]
        if stick:
            argv += ["-drive", f"if=none,id=stick,file={os.path.abspath(stick)},format=raw",
                     "-device", "usb-storage,drive=stick"]
        if fast:
            argv += ["-icount", "shift=auto,sleep=off"]
        return argv + list(extra)

    def start(self, kernel, nand=None, nand_write=False, psp=None, initrd=None, append=None, stick=None,
              fast=False, props=None, qemu=None, extra=(), timeout=30):
        """Starts the machine, headless, and returns once its QMP socket
        answers. NAND is attached with snapshot=on (never changed) unless
        NAND_WRITE; with PSP, a directory, the machine boots a copy of
        NAND in this directory whose settings partition is a JFFS2 image of
        PSP. STICK, an image, is a USB stick (usb-storage), written as the
        guest writes it. PROPS are the machine's properties (accel-x=...,
        guid=...); EXTRA, more QEMU options."""
        if self.running():
            raise Error(f"the machine is already running ({self.path})")
        qemu = find_qemu(qemu)
        os.makedirs(self.path, exist_ok=True)
        for name in (PID, QMP_SOCK, CON_SOCK, LOG, QEMU_LOG, "screen.ppm"):
            try:
                os.unlink(self.at(name))
            except FileNotFoundError:
                pass
        if not os.path.exists(kernel):
            raise Error(f"{kernel}: no such kernel")
        if psp:
            if not nand:
                raise Error("a settings directory needs a NAND image")
            copy = self.at("nand.img")
            nand_with(nand, copy, {"PSP": jffs2(psp, PARTITIONS["PSP"][1])})
            nand, nand_write = copy, True
        argv = self.command_line(qemu, kernel, nand, nand_write, initrd, append, stick, fast, props, extra)
        with open(self.at(CONFIG), "w") as f:
            json.dump({"argv": argv, "stick": stick and os.path.abspath(stick), "started": time.time()}, f)
        open(self.at(LOG), "wb").close()
        with open(self.at(QEMU_LOG), "wb") as out:
            p = subprocess.Popen(argv, cwd=self.path, stdin=subprocess.DEVNULL, stdout=out, stderr=out,
                                 start_new_session=True)
        with open(self.at(PID), "w") as f:
            f.write(f"{p.pid}\n")
        deadline = time.monotonic() + timeout
        while True:
            if p.poll() is not None:
                raise Error(f"QEMU exited ({p.returncode}):\n{self.read(QEMU_LOG, '')}")
            try:
                with QMP(self.at(QMP_SOCK), 10):
                    return p.pid
            except (OSError, ValueError):
                if time.monotonic() > deadline:
                    self.kill()
                    raise Error(f"QEMU's QMP socket didn't answer:\n{self.read(QEMU_LOG, '')}")
                time.sleep(0.1)

    def kill(self):
        pid = self.pid()
        if pid:
            os.kill(pid, signal.SIGKILL)
            self.wait_gone(5)

    def wait_gone(self, secs):
        deadline = time.monotonic() + secs
        while self.running():
            if time.monotonic() > deadline:
                return False
            time.sleep(0.05)
        return True

    def stop(self):
        """Quits QEMU (or kills it, if it doesn't answer)."""
        if not self.running():
            return
        try:
            with self.qmp(10) as q:
                q.cmd("quit")
        except (OSError, ValueError, Error):
            pass
        if not self.wait_gone(10):
            self.kill()

    def status(self):
        if not self.running():
            return {"running": False}
        with self.qmp() as q:
            s = q.cmd("query-status")
            out = {"running": True, "status": s.get("status"), "pid": self.pid()}
            try:
                out.update(q.cmd("query-chumby-state"))
            except Error:
                pass
        return out

    # The console.

    def log(self):
        """The console's output so far: bytes as Latin-1 characters, so
        that an offset in it is one in the file."""
        with open(self.at(LOG), "rb") as f:
            return f.read().decode("latin-1")

    def wait_log(self, pattern, secs=30, since=0):
        """Waits until the console's log (from offset SINCE) matches the
        regular expression, and returns the match. Raises Error on a
        timeout, or if QEMU exits first."""
        rx = re.compile(pattern, re.M)
        deadline = time.monotonic() + secs
        while True:
            m = rx.search(self.log(), since)
            if m:
                return m
            if not self.running():
                raise Error(f"the machine stopped before the console showed {pattern!r}")
            if time.monotonic() > deadline:
                raise Error(f"timed out after {secs:g} s waiting for {pattern!r} on the console")
            time.sleep(0.1)

    def type(self, text):
        """Types TEXT on the console: newlines as CR, in pieces the UART's
        32-character FIFO takes."""
        data = text.replace("\r\n", "\r").replace("\n", "\r").encode()
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(10)
        with s:
            connect(s, self.at(CON_SOCK))
            for i in range(0, len(data), 16):
                s.sendall(data[i:i + 16])
                time.sleep(0.02)
            # The last piece reaches the UART before the socket closes.
            time.sleep(0.05)

    def exec(self, command, secs=30):
        """Runs a shell command on the console (which must have a shell
        waiting there) and returns its exit status and output."""
        tag = "%08x" % int.from_bytes(os.urandom(4), "big")
        # An Enter first: a console that asks for one before it starts a
        # shell ("Please press Enter to activate this console") gets it,
        # and a shell already there prints a fresh prompt. Then a moment
        # for what that prints to stop.
        self.type("\n")
        size, quiet, deadline = -1, time.monotonic(), time.monotonic() + 5
        while time.monotonic() < deadline and time.monotonic() - quiet < 0.5:
            now = os.path.getsize(self.at(LOG))
            if now != size:
                size, quiet = now, time.monotonic()
            time.sleep(0.05)
        since = os.path.getsize(self.at(LOG))
        # The marker as printed differs from the command as echoed.
        self.type(f"{command}; echo @@{tag}''END $?\n")
        m = self.wait_log(rf"@@{tag}END (\d+)\r?$", secs, since=since)
        out = self.log()[since:m.start()]
        # The command's own echo, then its output.
        first = out.find("\n")
        out = out[first + 1:] if first >= 0 else ""
        return int(m.group(1)), out.replace("\r\n", "\n")

    # Inputs.

    def tap(self, x, y, hold_ms=150):
        self.down(x, y)
        time.sleep(hold_ms / 1000)
        self.up()

    def down(self, x, y):
        if not (0 <= x < W and 0 <= y < H):
            raise Error(f"({x}, {y}) is off the {W}x{H} screen")
        with self.qmp() as q:
            q.cmd("input-send-event", events=pen_events(True, x, y))

    def up(self):
        with self.qmp() as q:
            q.cmd("input-send-event", events=pen_events(False))

    def button(self, how, hold_ms=300):
        """The top button: down, up, or tap (pressed for HOLD_MS)."""
        if how not in ("down", "up", "tap"):
            raise Error("the button goes down, up or tap")
        with self.qmp() as q:
            if how in ("down", "tap"):
                q.qom_set("button", True)
            if how == "tap":
                time.sleep(hold_ms / 1000)
            if how in ("up", "tap"):
                q.qom_set("button", False)

    def headphones(self, inserted):
        with self.qmp() as q:
            q.qom_set("headphones", bool(inserted))

    def accel(self, x, y, z):
        with self.qmp() as q:
            for prop, v in zip(("accel-x", "accel-y", "accel-z"), (x, y, z)):
                q.qom_set(prop, int(v))

    def chumby_state(self):
        with self.qmp() as q:
            return q.cmd("query-chumby-state")

    # The screen.

    def shot(self, out):
        """The screen, as a PNG."""
        with self.qmp() as q:
            q.cmd("screendump", filename=os.path.abspath(out), format="png")

    def screen(self):
        """The screen's 8-bit RGB pixels, row by row."""
        ppm = self.at("screen.ppm")
        with self.qmp() as q:
            q.cmd("screendump", filename=ppm, format="ppm")
        with open(ppm, "rb") as f:
            return ppm_rgb(f.read())

    def pixel(self, x, y):
        if not (0 <= x < W and 0 <= y < H):
            raise Error(f"({x}, {y}) is off the {W}x{H} screen")
        i = (y * W + x) * 3
        return "#%02x%02x%02x" % tuple(self.screen()[i:i + 3])

    def wait_screen(self, secs=30, settle=0.5):
        """Waits until the screen has stopped changing for SETTLE seconds
        and isn't all black."""
        deadline = time.monotonic() + secs
        last, since = None, time.monotonic()
        while True:
            now = self.screen()
            if now != last:
                last, since = now, time.monotonic()
            elif any(now) and time.monotonic() - since >= settle:
                return
            if time.monotonic() > deadline:
                raise Error(f"timed out after {secs:g} s waiting for the screen to settle")
            time.sleep(0.1)

    def compare(self, files, least=0.0, secs=0.0, want=None, masks=()):
        """Which picture the screen is most like, and the share of its
        pixels that match, as (share, name); with SECS, until the best
        matches at least LEAST of them and its name matches WANT. Raises
        Error if it never does."""
        keep = masked(masks) if masks else None
        pictures = {}
        for f in files:
            p = picture(f)
            pictures[os.path.basename(f)] = [p[i] for i in keep] if keep else p
        if not pictures:
            raise Error("no pictures to compare with")
        deadline = time.monotonic() + secs
        while True:
            now = rgb_to_rgb565(self.screen())
            if keep:
                now = [now[i] for i in keep]
            share, name = max((sum(a == b for a, b in zip(now, p)) / len(now), n) for n, p in pictures.items())
            ok = share >= least and (not want or re.search(want, name))
            if ok:
                return share, name
            if time.monotonic() >= deadline:
                if secs or least or want:
                    raise Error(f"the screen is most like {name} ({share:.2f})")
                return share, name
            time.sleep(0.3)

    # The power.

    def powercut(self, out):
        """The power cut: the machine stopped where it is, the stick image
        copied to OUT as it stands (what the guest hadn't written to it is
        lost, as on a stick), then QEMU killed. OUT is the stick to boot
        next."""
        stick = self.config().get("stick")
        if not stick:
            raise Error("the machine has no stick")
        with self.qmp() as q:
            q.cmd("stop")
            # Writes QEMU had taken from the guest reach the image file.
            try:
                q.cmd("human-monitor-command", **{"command-line": "commit all"})
            except Error:
                pass
            shutil.copyfile(stick, out)
        self.kill()


# Images.

# The NAND chip, as nanddump and the machine store it: 131072 records of a
# 512-byte page and its 16 spare bytes.
PAGE, SPARE = 512, 16
RECORD = PAGE + SPARE
PAGES = 131072
NAND_BYTES = PAGES * RECORD
ERASE_BLOCK = 0x4000
# The stock partitions: offset and size of each, in data bytes.
PARTITIONS = {
    "Boot_Loader": (0x0000000, 0x0100000),
    "PSP": (0x0100000, 0x0200000),
    "Kernel2": (0x0300000, 0x0280000),
    "Root_Disk2": (0x0580000, 0x0800000),
    "Kernel1": (0x0d80000, 0x0300000),
    "Root_Disk1": (0x1080000, 0x1600000),
    "Cache": (0x2680000, 0x1800000),
    "MSP": (0x3f80000, 0x0080000),
}

# JFFS2, as chumby-image writes it: little-endian, 16 KiB erase blocks,
# uncompressed (or zlib, asked), no clean markers, every node at a fixed
# time, so that images are reproducible.
JFFS2_TIME = 1230768000
JFFS2_COMPR_ZLIB = 6
S_IFDIR, S_IFREG, S_IFLNK = 0o040000, 0o100000, 0o120000
DT_DIR, DT_REG, DT_LNK = 4, 8, 10


def jffs2_crc(data):
    """CRC-32 from 0 with no final inversion, as JFFS2 has it."""
    return zlib.crc32(data, 0xFFFFFFFF) ^ 0xFFFFFFFF


class _Jffs2:
    def __init__(self, compress=False):
        self.out = bytearray()
        self.next_ino = 2
        self.compress = compress

    def push(self, node):
        size = (len(node) + 3) & ~3
        room = ERASE_BLOCK - len(self.out) % ERASE_BLOCK
        if size > room:
            self.out += b"\xff" * room
        self.out += node + bytes(size - len(node))

    @staticmethod
    def header(kind, total):
        h = (0x1985).to_bytes(2, "little") + kind.to_bytes(2, "little") + total.to_bytes(4, "little")
        return h + jffs2_crc(h).to_bytes(4, "little")

    def dirent(self, pino, version, ino, name, dtype):
        n = self.header(0xE001, 40 + len(name))
        for v in (pino, version, ino, JFFS2_TIME):
            n += v.to_bytes(4, "little")
        n += bytes([len(name), dtype, 0, 0])
        n += jffs2_crc(n[:32]).to_bytes(4, "little") + jffs2_crc(name).to_bytes(4, "little") + name
        self.push(n)

    def inode(self, ino, version, mode, isize, offset, data):
        stored, compr = data, 0
        if self.compress and data:
            z = zlib.compress(data, 9)
            if len(z) < len(data):
                stored, compr = z, JFFS2_COMPR_ZLIB
        n = self.header(0xE002, 68 + len(stored))
        for v in (ino, version, mode):
            n += v.to_bytes(4, "little")
        n += bytes(4)  # uid, gid: root
        for v in (isize, JFFS2_TIME, JFFS2_TIME, JFFS2_TIME, offset, len(stored), len(data)):
            n += v.to_bytes(4, "little")
        n += bytes([compr, 0, 0, 0])  # the compressor; flags 0
        n += jffs2_crc(stored).to_bytes(4, "little")
        n += jffs2_crc(n[:60]).to_bytes(4, "little") + stored
        self.push(n)

    def add_dir(self, path, ino):
        for version, name in enumerate(sorted(os.listdir(path), key=os.fsencode), 1):
            child_path = os.path.join(path, name)
            raw = os.fsencode(name)
            st = os.lstat(child_path)
            perm = st.st_mode & 0o7777
            child = self.next_ino
            self.next_ino += 1
            if os.path.isdir(child_path) and not os.path.islink(child_path):
                self.inode(child, 1, S_IFDIR | perm, 0, 0, b"")
                self.dirent(ino, version, child, raw, DT_DIR)
                self.add_dir(child_path, child)
            elif os.path.islink(child_path):
                target = os.fsencode(os.readlink(child_path))
                self.inode(child, 1, S_IFLNK | 0o777, len(target), 0, target)
                self.dirent(ino, version, child, raw, DT_LNK)
            else:
                with open(child_path, "rb") as f:
                    data = f.read()
                if not data:
                    self.inode(child, 1, S_IFREG | perm, 0, 0, b"")
                for i in range(0, len(data), 4096):
                    self.inode(child, 1 + i // 4096, S_IFREG | perm, len(data), i, data[i:i + 4096])
                self.dirent(ino, version, child, raw, DT_REG)


def jffs2(path, size, compress=False):
    """A JFFS2 image of the directory, padded with erased flash to SIZE
    bytes (byte for byte what `chumby-image mkpsp` makes); with COMPRESS,
    each block of a file zlib-compressed where that's smaller."""
    j = _Jffs2(compress)
    j.add_dir(path, 1)
    if len(j.out) > size:
        raise Error(f"{path} doesn't fit: {len(j.out)} bytes of JFFS2 in a {size}-byte partition")
    return bytes(j.out) + b"\xff" * (size - len(j.out))


def nand_with(nand, out, partitions):
    """A copy of a NAND image at OUT with partitions' data replaced:
    PARTITIONS maps a partition's name to its new contents, each page
    written with a blank spare area."""
    if os.path.getsize(nand) != NAND_BYTES:
        raise Error(f"{nand}: not a NAND image of {NAND_BYTES} bytes")
    shutil.copyfile(nand, out)
    with open(out, "r+b") as f:
        for name, data in partitions.items():
            offset, size = PARTITIONS[name]
            if len(data) != size:
                raise Error(f"{name}: {len(data)} bytes for a {size}-byte partition")
            f.seek(offset // PAGE * RECORD)
            f.write(b"".join(data[i:i + PAGE] + b"\xff" * SPARE for i in range(0, size, PAGE)))


# A stick: a FAT16 file system in the first partition of an MBR disk image,
# as a USB stick is formatted, with long names (VFAT). Everything is laid
# out at once; links are followed.

SECTOR = 512
FAT_START = 2048  # the partition's first sector: 1 MiB in
FAT_TIME, FAT_DATE = 0, (2009 - 1980) << 9 | 1 << 5 | 1  # 2009-01-01 00:00


def _short_names():
    n = 0
    while True:
        n += 1
        yield ("N%07X" % n).encode(), b"   "


def _lfn_entries(name, short):
    check = 0
    for c in short:
        check = ((check & 1) << 7 | check >> 1) + c & 0xFF
    units = list(name.encode("utf-16-le"))
    chars = [units[i] | units[i + 1] << 8 for i in range(0, len(units), 2)]
    if len(chars) > 255:
        raise Error(f"{name}: too long a name for FAT")
    if len(chars) % 13:
        chars += [0] + [0xFFFF] * (12 - len(chars) % 13)
    pieces = [chars[i:i + 13] for i in range(0, len(chars), 13)]
    out = []
    for seq in range(len(pieces), 0, -1):
        p = pieces[seq - 1]
        e = bytes([seq | (0x40 if seq == len(pieces) else 0)])
        e += b"".join(struct.pack("<H", c) for c in p[:5])
        e += bytes([0x0F, 0, check])
        e += b"".join(struct.pack("<H", c) for c in p[5:11])
        e += b"\0\0" + b"".join(struct.pack("<H", c) for c in p[11:13])
        out.append(e)
    return b"".join(out)


def _dirent(short, attr, cluster, size):
    return struct.pack("<11sBBBHHHHHHHI", short, attr, 0, 0, FAT_TIME, FAT_DATE, FAT_DATE,
                       cluster >> 16, FAT_TIME, FAT_DATE, cluster & 0xFFFF, size)


def mkfat(src, out, size_mb=None, label="CHUMBY"):
    """A stick image at OUT: an MBR with one FAT16 partition holding SRC's
    files (or none, if SRC is None). SIZE_MB defaults to room for SRC
    twice over, at least 64 MiB."""
    def size_of(d):
        """The bytes of the files under D, links followed."""
        n = 0
        for name in os.listdir(d):
            p = os.path.join(d, name)
            n += size_of(p) if os.path.isdir(p) else os.path.getsize(p)
        return n

    used = size_of(src) if src else 0
    if size_mb is None:
        size_mb = max(64, (2 * used >> 20) + 16)
    total = (size_mb << 20) // SECTOR - FAT_START
    spc = 1
    while total // spc > 65000:
        spc *= 2
    if spc > 64:
        raise Error(f"{size_mb} MiB is too big for FAT16")
    if total // spc < 4100:
        raise Error(f"{size_mb} MiB is too small for FAT16")
    reserved, root_entries = 4, 512
    root_sectors = root_entries * 32 // SECTOR
    fat_sectors = 1
    while True:
        clusters = (total - reserved - 2 * fat_sectors - root_sectors) // spc
        need = -(-(clusters + 2) * 2 // SECTOR)
        if need <= fat_sectors:
            break
        fat_sectors = need
    csize = spc * SECTOR
    data_start = reserved + 2 * fat_sectors + root_sectors

    fat = [0xFFF8, 0xFFFF]
    contents = {}  # cluster -> bytes to write there (a file's or a directory's whole run)

    def alloc(nbytes):
        n = max(1, -(-nbytes // csize))
        first = len(fat)
        if first + n - 2 > clusters:
            raise Error(f"{src} doesn't fit in {size_mb} MiB")
        fat.extend(list(range(first + 1, first + n)) + [0xFFFF])
        return first

    names = _short_names()

    def lfn_count(name):
        return -(-len(name.encode("utf-16-le")) // 26)

    def entries_for(d, me, parent):
        """Directory D's entries (D at cluster ME, its parent at PARENT,
        0 for the root); its children are laid out as they come."""
        out = b""
        if me:
            out += _dirent(b".          ", 0x10, me, 0) + _dirent(b"..         ", 0x10, parent, 0)
        for name in sorted(os.listdir(d)):
            p = os.path.join(d, name)
            base, ext = next(names)
            short = base + ext
            if os.path.isdir(p):
                n = 2 + sum(1 + lfn_count(c) for c in os.listdir(p))
                cl = alloc(n * 32)
                contents[cl] = entries_for(p, cl, me)
                out += _lfn_entries(name, short) + _dirent(short, 0x10, cl, 0)
            else:
                with open(p, "rb") as f:
                    data = f.read()
                cl = alloc(len(data)) if data else 0
                if data:
                    contents[cl] = data
                out += _lfn_entries(name, short) + _dirent(short, 0x20, cl, len(data))
        return out

    label = label.upper().encode()[:11].ljust(11)
    root = struct.pack("<11sB", label, 0x08) + bytes(20)
    if src:
        root += entries_for(src, 0, 0)
    if len(root) > root_entries * 32:
        raise Error(f"{src}: too many entries at the top")

    with open(out, "wb") as f:
        f.truncate((FAT_START + total) * SECTOR)
        # The MBR: one FAT16 partition (type 6).
        mbr = bytearray(SECTOR)
        mbr[440:444] = os.urandom(4)
        mbr[446:462] = struct.pack("<B3sB3sII", 0, b"\xfe\xff\xff", 0x06, b"\xfe\xff\xff", FAT_START, total)
        mbr[510:512] = b"\x55\xaa"
        f.write(mbr)
        bpb = bytearray(SECTOR)
        bpb[0:3] = b"\xeb\x3c\x90"
        bpb[3:11] = b"MSWIN4.1"
        struct.pack_into("<HBHBHHBHHHII", bpb, 11, SECTOR, spc, reserved, 2, root_entries,
                         total if total < 0x10000 else 0, 0xF8, fat_sectors, 32, 64, FAT_START,
                         total if total >= 0x10000 else 0)
        struct.pack_into("<BBBI11s8s", bpb, 36, 0x80, 0, 0x29, int.from_bytes(os.urandom(4), "little"),
                         label, b"FAT16   ")
        bpb[510:512] = b"\x55\xaa"
        f.seek(FAT_START * SECTOR)
        f.write(bpb)
        table = b"".join(struct.pack("<H", v) for v in fat)
        for i in range(2):
            f.seek((FAT_START + reserved + i * fat_sectors) * SECTOR)
            f.write(table)
        f.seek((FAT_START + reserved + 2 * fat_sectors) * SECTOR)
        f.write(root)
        for cl, data in contents.items():
            f.seek((FAT_START + data_start + (cl - 2) * spc) * SECTOR)
            f.write(data)


def fat_files(image):
    """The files in a stick image's FAT16 partition, as {path: bytes}
    (directories with None): for tests, and to look at a stick after a
    run without mounting it."""
    with open(image, "rb") as f:
        mbr = f.read(SECTOR)
        start = struct.unpack_from("<I", mbr, 454)[0]
        f.seek(start * SECTOR)
        bpb = f.read(SECTOR)
        _, spc, reserved, nfats, root_entries, _, _, fat_sectors = struct.unpack_from("<HBHBHHBH", bpb, 11)
        f.seek((start + reserved) * SECTOR)
        raw = f.read(fat_sectors * SECTOR)
        fat = list(struct.unpack(f"<{len(raw) // 2}H", raw))
        root_at = start + reserved + nfats * fat_sectors
        data_at = root_at + root_entries * 32 // SECTOR
        f.seek(root_at * SECTOR)
        root = f.read(root_entries * 32)

        def chain(cl):
            out = b""
            while 2 <= cl < 0xFFF8:
                f.seek((data_at + (cl - 2) * spc) * SECTOR)
                out += f.read(spc * SECTOR)
                cl = fat[cl]
            return out

        found = {}

        def walk(data, prefix):
            lfn = []
            for i in range(0, len(data), 32):
                e = data[i:i + 32]
                if e[0] == 0:
                    break
                if e[0] == 0xE5:
                    continue
                if e[11] == 0x0F:
                    units = e[1:11] + e[14:26] + e[28:32]
                    lfn.insert(0, units)
                    continue
                if e[11] & 0x08 or e[:11] in (b".          ", b"..         "):
                    lfn = []
                    continue
                if lfn:
                    name = b"".join(lfn).decode("utf-16-le").split("\0")[0]
                else:
                    name = (e[:8].decode().strip() + "." + e[8:11].decode().strip()).rstrip(".")
                lfn = []
                cl = struct.unpack_from("<H", e, 26)[0]
                size = struct.unpack_from("<I", e, 28)[0]
                path = prefix + name
                if e[11] & 0x10:
                    found[path] = None
                    walk(chain(cl), path + "/")
                else:
                    found[path] = chain(cl)[:size] if size else b""

        walk(root, "")
        return found
