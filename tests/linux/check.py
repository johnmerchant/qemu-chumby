# SPDX-License-Identifier: GPL-2.0-or-later
"""Desktop checks for tests/linux/run, inside its container.

usage: dbus-run-session -- python3 -I check.py OUT

Boots the stock firmware (/images/zImage, /images/nand.img) in KDE's
window manager, KWin, both on X11 (on a virtual X server) and as a
headless Wayland compositor, with PulseAudio for sound, and checks what a
desktop user gets: QEMU's GTK and SDL windows show the Chumby, QEMU plays
into PulseAudio, and chumby-emu's Qt panel comes up and drives the
machine. Screenshots and logs go in OUT.
"""
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time

QEMU = os.environ.get("QEMU", "qemu-system-arm")
QDBUS = shutil.which("qdbus6") or shutil.which("qdbus") or "qdbus"
SRC = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = sys.argv[1]
os.makedirs(OUT, exist_ok=True)
TMP = tempfile.mkdtemp(prefix="qc-")
os.chmod(TMP, 0o700)
failures = []
started = []


def log(*a):
    print(*a, flush=True)


def check(ok, what):
    log(("PASS " if ok else "FAIL ") + what)
    if not ok:
        failures.append(what)
    return ok


def run(*args, **kw):
    return subprocess.run(args, capture_output=True, text=True, **kw)


def spawn(args, name, env=None):
    f = open(os.path.join(OUT, name + ".log"), "w")
    p = subprocess.Popen(args, stdout=f, stderr=subprocess.STDOUT, env=env)
    started.append(p)
    return p


def wait_for(fn, timeout, step=0.2):
    end = time.time() + timeout
    while time.time() < end:
        if fn():
            return True
        time.sleep(step)
    return False


class QMP:
    def __init__(self, path):
        self.s = socket.socket(socket.AF_UNIX)
        if not wait_for(lambda: self._connect(path), 20):
            raise RuntimeError("no QMP at " + path)
        self.f = self.s.makefile("rw")
        self.f.readline()
        self.cmd("qmp_capabilities")

    def _connect(self, path):
        try:
            self.s.connect(path)
            return True
        except OSError:
            return False

    def cmd(self, name, **args):
        self.f.write(json.dumps({"execute": name, "arguments": args}) + "\n")
        self.f.flush()
        while True:
            r = json.loads(self.f.readline())
            if "return" in r or "error" in r:
                return r


class Console:
    def __init__(self, path):
        self.s = socket.socket(socket.AF_UNIX)
        wait_for(lambda: self._connect(path), 20)
        self.s.settimeout(0.2)
        self.buf = b""

    def _connect(self, path):
        try:
            self.s.connect(path)
            return True
        except OSError:
            return False

    def pump(self, sec):
        end = time.time() + sec
        while time.time() < end:
            try:
                d = self.s.recv(65536)
                if not d:
                    return
                self.buf += d
            except socket.timeout:
                pass

    def send(self, line):
        for i in range(0, len(line), 16):
            self.s.sendall(line[i:i + 16].encode())
            time.sleep(0.01)
        self.s.sendall(b"\r")

    def shell(self, timeout=300):
        end = time.time() + timeout
        while time.time() < end:
            self.send("echo READY_$((20+22))")
            self.pump(3)
            if b"READY_42" in self.buf:
                return True
        return False


def stock_args(tag, display, env_audio=True):
    q = os.path.join(TMP, tag + ".q")
    c = os.path.join(TMP, tag + ".c")
    args = [QEMU, "-M", "chumby-classic", "-name", "Chumby " + tag,
            "-kernel", "/images/zImage",
            "-drive", "if=mtd,file=/images/nand.img,format=raw,snapshot=on",
            "-serial", f"unix:{c},server=on,wait=off",
            "-qmp", f"unix:{q},server=on,wait=off",
            "-monitor", "none", "-nic", "none", "-no-reboot",
            "-icount", "shift=auto,sleep=off", "-display", display]
    if env_audio:
        # The codec plays to the machine's audiodev.
        args[2] = "chumby-classic,audiodev=snd0"
        args += ["-audiodev", "pa,id=snd0"]
    return args, q, c


def colours(png):
    return int(run("convert", png, "-format", "%k", "info:").stdout.strip() or 0)


# -- the build's backends ---------------------------------------------------
displays = set(run(QEMU, "-display", "help").stdout.split())
audiodevs = set(run(QEMU, "-audiodev", "help").stdout.split())
for d in ("gtk", "sdl"):
    check(d in displays, f"build: display backend {d}")
for a in ("pa", "pipewire", "alsa"):
    check(a in audiodevs, f"build: audio backend {a}")
machine_help = run(QEMU, "-M", "chumby-classic,help").stdout
has_audiodev_prop = "audiodev" in machine_help

# -- sound: PulseAudio with a null sink ---------------------------------------
os.environ["XDG_RUNTIME_DIR"] = TMP
pa = run("pulseaudio", "--daemonize=yes", "--exit-idle-time=-1", "-n",
         "--load=module-native-protocol-unix",
         "--load=module-null-sink sink_name=chumby",
         "--load=module-always-sink")
check(wait_for(lambda: run("pactl", "info").returncode == 0, 10),
      "PulseAudio is running " + pa.stderr.strip()[-60:])


def kwin_windows(kwin_log):
    """The captions of KWin's windows, from a KWin script."""
    js = os.path.join(TMP, "list.js")
    with open(js, "w") as f:
        f.write("var l = workspace.clientList ? workspace.clientList() : workspace.windowList();\n"
                "for (var i = 0; i < l.length; i++) print('KWINWIN ' + l[i].caption);\n")
    tag = "list%d" % int(time.time() * 1000)
    r = run(QDBUS, "org.kde.KWin", "/Scripting", "org.kde.kwin.Scripting.loadScript", js, tag)
    sid = r.stdout.strip()
    if not sid.lstrip("-").isdigit() or int(sid) < 0:
        return None
    for path in ("/Scripting/Script" + sid, "/" + sid):
        if run(QDBUS, "org.kde.KWin", path, "org.kde.kwin.Script.run").returncode == 0:
            break
    time.sleep(1)
    run(QDBUS, "org.kde.KWin", "/Scripting", "org.kde.kwin.Scripting.unloadScript", tag)
    text = open(kwin_log, errors="replace").read()
    return [l.split("KWINWIN ", 1)[1].strip() for l in text.splitlines() if "KWINWIN " in l]


def session(kind):
    """One KDE session: KWin on X11 or Wayland, then the checks."""
    env = dict(os.environ, QT_LOGGING_RULES="kwin_scripting=true")
    if kind == "x11":
        xvfb = spawn(["Xvfb", ":99", "-screen", "0", "1280x800x24", "-nolisten", "tcp"], "xvfb")
        env["DISPLAY"] = ":99"
        wait_for(lambda: run("xdpyinfo", env=env).returncode == 0, 10)
        kwin = spawn(["kwin_x11", "--replace"], "kwin-x11", env=env)
        kwin_log = os.path.join(OUT, "kwin-x11.log")
        env["QT_QPA_PLATFORM"] = "xcb"
        env["GDK_BACKEND"] = "x11"
        env["SDL_VIDEODRIVER"] = "x11"
    else:
        env.pop("DISPLAY", None)
        sock = "wayland-chumby"
        kwin = spawn(["kwin_wayland", "--virtual", "--xwayland", "--socket", sock,
                      "--width", "1280", "--height", "800"], "kwin-wayland", env=env)
        kwin_log = os.path.join(OUT, "kwin-wayland.log")
        env["WAYLAND_DISPLAY"] = sock
        wait_for(lambda: os.path.exists(os.path.join(TMP, sock)), 20)
        env["QT_QPA_PLATFORM"] = "wayland"
        env["GDK_BACKEND"] = "wayland"
        env["SDL_VIDEODRIVER"] = "wayland"
    up = wait_for(lambda: run(QDBUS, "org.kde.KWin", env=env).returncode == 0, 30)
    if not check(up and kwin.poll() is None, f"{kind}: KWin is running"):
        return

    for display in ("gtk", "sdl"):
        if display not in displays:
            continue
        tag = f"{kind}-{display}"
        args, q, c = stock_args(tag, display)
        p = spawn(args, tag + "-qemu", env=env)
        qmp = QMP(q)
        con = Console(c)
        check(con.shell(), f"{tag}: the stock firmware reaches a shell")
        time.sleep(5)
        check(p.poll() is None, f"{tag}: QEMU's window is still up")
        wins = kwin_windows(kwin_log) or []
        check(any("Chumby " + tag in w for w in wins),
              f"{tag}: KWin manages the QEMU window ({wins})")
        if kind == "x11":
            shot = os.path.join(OUT, tag + "-desktop.png")
            run("import", "-window", "root", shot, env=env)
            n = colours(shot)
            check(n > 16, f"{tag}: the desktop shows the Chumby's screen ({n} colours)")
        qmp.cmd("screendump", filename=os.path.join(OUT, tag + "-screen.png"), format="png")
        clients = run("pactl", "list", "clients").stdout.lower()
        check("qemu" in clients, f"{tag}: QEMU is a PulseAudio client")
        qmp.cmd("quit")
        p.wait(20)
        with open(os.path.join(OUT, tag + "-console.txt"), "wb") as f:
            f.write(con.buf)

    # chumby-emu, with its Qt panel; a second QMP socket for the check.
    tag = f"{kind}-emu"
    q2 = os.path.join(TMP, tag + ".q")
    display = "gtk" if "gtk" in displays else "sdl"
    emu = spawn([sys.executable, os.path.join(SRC, "chumby-emu"), "/images",
                 "--qemu", QEMU, "--display", display, "--audio", "pa", "--fast",
                 "--", "-qmp", f"unix:{q2},server=on,wait=off"], tag, env=env)
    qmp = QMP(q2)
    check(wait_for(lambda: any(w.strip() == "Chumby" for w in (kwin_windows(kwin_log) or [])), 60, 2),
          f"{tag}: the panel window is up")
    st = qmp.cmd("query-status").get("return", {})
    check(st.get("running"), f"{tag}: the machine is running ({st})")
    if kind == "x11":
        wid = run("xdotool", "search", "--name", "^Chumby$", env=env).stdout.split()
        if check(bool(wid), f"{tag}: xdotool finds the panel"):
            run("xdotool", "windowactivate", "--sync", wid[0], env=env)
            run("xdotool", "keydown", "space", env=env)
            time.sleep(0.5)
            held = qmp.cmd("qom-get", path="/machine", property="button").get("return")
            run("xdotool", "keyup", "space", env=env)
            time.sleep(0.5)
            free = qmp.cmd("qom-get", path="/machine", property="button").get("return")
            check(held is True and free is False,
                  f"{tag}: Space in the panel holds the top button ({held}, then {free})")
            shot = os.path.join(OUT, tag + "-desktop.png")
            run("import", "-window", "root", shot, env=env)
    qmp.cmd("quit")
    try:
        emu.wait(20)
    except subprocess.TimeoutExpired:
        emu.kill()
    check(emu.returncode is not None, f"{tag}: chumby-emu exits with the machine")

    kwin.terminate()
    if kind == "x11":
        xvfb.terminate()


try:
    for kind in ("x11", "wayland"):
        session(kind)
finally:
    for p in started:
        if p.poll() is None:
            p.terminate()
    run("pulseaudio", "--kill")
    shutil.rmtree(TMP, ignore_errors=True)

if failures:
    log(f"{len(failures)} failed:")
    for f in failures:
        log("  " + f)
    sys.exit(1)
log("all passed")
