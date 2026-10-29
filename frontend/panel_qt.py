# SPDX-License-Identifier: GPL-2.0-or-later
"""chumby-emu's control panel, in Qt 6 (PySide6, or PyQt6 if that's what
is installed): native on KDE and the other Linux desktops, and on macOS.

Everything here goes through QMP. Controls whose machine property the
running QEMU lacks are shown disabled, so the panel works with older
builds of the machine too.
"""
import math
import os
import queue
import re
import sys
import socket
import threading

try:
    from PySide6 import QtCore, QtGui, QtWidgets
except ImportError:  # pragma: no cover
    from PyQt6 import QtCore, QtGui, QtWidgets

try:
    import mac_motion
except ImportError:  # pragma: no cover
    mac_motion = None

# The machine's control surface (docs/system/arm/chumby-classic.rst,
# "Control surface"). Properties are on /machine.
PROP_BUTTON = "button"
PROP_HEADPHONES = "headphones"
PROP_ACCEL = ("accel-x", "accel-y", "accel-z")     # milli-g
QUERY_OUTPUTS = "query-chumby-state"
EVENT_PREFIX = "CHUMBY_"


# Terminal output: escape sequences (CSI; OSC, such as a window title;
# lone ESC + one character),
# backspace and BEL; the rest is text.
_TERM = re.compile(r"\x1b\[([0-?]*)[ -/]*([@-~])|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)"
                   r"|\x1b[@-Z\\-_]|[\x08\x07]")

# The 16 ANSI colours, as xterm draws them
_ANSI = ["#000000", "#cd0000", "#00a000", "#cdcd00", "#3b6fe0", "#cd00cd", "#00b0b0", "#bfbfbf",
         "#7f7f7f", "#ff4040", "#00d000", "#e0e000", "#6f9fff", "#ff40ff", "#00e0e0", "#ffffff"]


class Terminal:
    """Writes a console's output into a QPlainTextEdit, as a terminal
    would: colour and bold from SGR sequences, backspace, and every other
    control sequence (cursor movement, title, ...) dropped."""

    def __init__(self, view):
        self.view = view
        self.base = QtGui.QTextCharFormat()
        self.fmt = QtGui.QTextCharFormat(self.base)
        self.bold = False
        self.fg = None
        self.pending = ""

    def sgr(self, params):
        codes = [int(c) if c.isdigit() else 0 for c in (params or "0").split(";")]
        for c in codes:
            if c == 0:
                self.bold, self.fg = False, None
                self.fmt = QtGui.QTextCharFormat(self.base)
            elif c == 1:
                self.bold = True
            elif c == 22:
                self.bold = False
            elif 30 <= c <= 37 or 90 <= c <= 97:
                self.fg = (c - 30) if c < 90 else (c - 90 + 8)
            elif c == 39:
                self.fg = None
            elif 40 <= c <= 47:
                self.fmt.setBackground(QtGui.QColor(_ANSI[c - 40]))
            elif c == 49:
                self.fmt.clearBackground()
        self.fmt.setFontWeight(QtGui.QFont.Weight.Bold if self.bold else QtGui.QFont.Weight.Normal)
        if self.fg is None:
            self.fmt.clearForeground()
        else:
            # Bold brightens the eight basic colours, as terminals do.
            fg = self.fg + 8 if self.bold and self.fg < 8 else self.fg
            self.fmt.setForeground(QtGui.QColor(_ANSI[fg]))

    def write(self, text):
        text = self.pending + text
        self.pending = ""
        # Keep an escape sequence cut off at the end for the next write.
        cut = text.rfind("\x1b")
        if cut >= 0 and not _TERM.match(text, cut) and len(text) - cut < 32:
            text, self.pending = text[:cut], text[cut:]
        c = self.view.textCursor()
        c.movePosition(QtGui.QTextCursor.MoveOperation.End)
        pos = 0
        for m in _TERM.finditer(text):
            c.insertText(text[pos:m.start()], self.fmt)
            pos = m.end()
            s = m.group(0)
            if s == "\x08":
                c.deletePreviousChar()
            elif m.group(2) == "m":
                self.sgr(m.group(1))
        c.insertText(text[pos:], self.fmt)
        self.view.setTextCursor(c)
        self.view.ensureCursorVisible()


class Console(QtCore.QObject):
    """The Chumby's console (UART1) on QEMU's unix socket, which takes one
    client: the panel. It shares the console with terminals (chumby-term)
    through a socket of its own, term_path: what the Chumby prints goes to
    the panel's view and every terminal, and what any of them types goes
    to the Chumby, in order and paced for its UART."""
    received = QtCore.Signal(str) if hasattr(QtCore, "Signal") else QtCore.pyqtSignal(str)

    def __init__(self, path):
        super().__init__()
        self.s = socket.socket(socket.AF_UNIX)
        self.s.connect(path)
        self.outq = queue.Queue()
        self.terms = []
        self.lock = threading.Lock()
        self.term_path = path + ".term"
        self.server = socket.socket(socket.AF_UNIX)
        self.server.bind(self.term_path)
        self.server.listen(4)
        for fn in (self._read, self._write, self._accept):
            threading.Thread(target=fn, daemon=True).start()

    def _read(self):
        import codecs
        dec = codecs.getincrementaldecoder("utf-8")("replace")
        while True:
            try:
                d = self.s.recv(4096)
            except OSError:
                return
            if not d:
                return
            with self.lock:
                for t in list(self.terms):
                    try:
                        t.sendall(d)
                    except OSError:
                        self.terms.remove(t)
            self.received.emit(dec.decode(d).replace("\r", ""))

    def _write(self):
        # The UART's receive FIFO holds 32 characters: pieces of 16, a few
        # milliseconds apart (README.md, "Console").
        while True:
            data = self.outq.get()
            for i in range(0, len(data), 16):
                try:
                    self.s.sendall(data[i:i + 16])
                except OSError:
                    return
                threading.Event().wait(0.005)

    def _accept(self):
        while True:
            try:
                t, _ = self.server.accept()
            except OSError:
                return
            with self.lock:
                self.terms.append(t)
            threading.Thread(target=self._from_term, args=(t,), daemon=True).start()

    def _from_term(self, t):
        while True:
            try:
                d = t.recv(1024)
            except OSError:
                d = b""
            if not d:
                with self.lock:
                    if t in self.terms:
                        self.terms.remove(t)
                return
            self.outq.put(d)

    def send(self, line):
        self.outq.put((line + "\r").encode())


class Panel(QtWidgets.QMainWindow):
    def __init__(self, qmp, events, con_path, proc, display, audio,
                 snapshot="chumby", other="chumby-fast"):
        super().__init__()
        self.qmp, self.events, self.proc = qmp, events, proc
        self.snapshot, self.other = snapshot, other
        self.setWindowTitle("Chumby")
        props = {p["name"] for p in qmp.cmd("qom-list", path="/machine")}
        self.has = lambda *names: all(n in props for n in names)

        central = QtWidgets.QWidget()
        self.setCentralWidget(central)
        grid = QtWidgets.QVBoxLayout(central)

        # -- paused: a banner across the top while the machine is stopped --
        self.banner = QtWidgets.QLabel(
            "\u23f8  Paused: the Chumby is stopped. Resume (Ctrl+P) to carry on.")
        self.banner.setAlignment(QtCore.Qt.AlignmentFlag.AlignCenter)
        self.banner.setWordWrap(True)
        self.banner.setStyleSheet(
            "QLabel { background: #f2b233; color: #1d1d1d; font-weight: bold;"
            " padding: 8px; border-radius: 4px; }")
        self.banner.hide()
        grid.addWidget(self.banner)

        # -- the top button ------------------------------------------------
        box = QtWidgets.QGroupBox("Top button")
        lay = QtWidgets.QHBoxLayout(box)
        self.button = QtWidgets.QPushButton("Squeeze")
        self.button.setToolTip("Held while the mouse button is down (or Space, in this window)")
        self.button.pressed.connect(lambda: self.set_button(True))
        self.button.released.connect(lambda: self.set_button(False))
        self.button.setEnabled(self.has(PROP_BUTTON))
        lay.addWidget(self.button)
        grid.addWidget(box)

        # -- tilt and shake -----------------------------------------------
        box = QtWidgets.QGroupBox("Motion")
        form = QtWidgets.QFormLayout(box)
        self.pitch = self.slider(-90, 90, 0)
        self.roll = self.slider(-180, 180, 0)
        form.addRow("Tilt forward/back", self.pitch)
        form.addRow("Tilt left/right", self.roll)
        row = QtWidgets.QHBoxLayout()
        for name, p, r in (("Upright", 0, 0), ("Face up", -90, 0),
                           ("On its side", 0, 90), ("Upside down", 0, 180)):
            b = QtWidgets.QPushButton(name)
            b.clicked.connect(lambda _=False, p=p, r=r: self.pose(p, r))
            row.addWidget(b)
        shake = QtWidgets.QPushButton("Shake")
        shake.clicked.connect(self.shake)
        row.addWidget(shake)
        form.addRow(row)
        self.gread = QtWidgets.QLabel()
        form.addRow("Acceleration", self.gread)
        self.follow = QtWidgets.QCheckBox("Follow this Mac's motion")
        self.follow.setToolTip("Tilt or shake the Mac's base and the Chumby feels it; "
                               "the Mac lying flat is the Chumby standing still")
        self.motion = None
        self.motion_g = None
        if mac_motion and mac_motion.available():
            form.addRow(self.follow)
            self.follow.toggled.connect(self.set_follow)
        box.setEnabled(self.has(*PROP_ACCEL))
        self.pitch.valueChanged.connect(self.send_tilt)
        self.roll.valueChanged.connect(self.send_tilt)
        grid.addWidget(box)

        # -- inputs and outputs ---------------------------------------------
        box = QtWidgets.QGroupBox("Jacks and outputs")
        form = QtWidgets.QFormLayout(box)
        self.headphones = QtWidgets.QCheckBox("Plugged in")
        self.headphones.setEnabled(self.has(PROP_HEADPHONES))
        self.headphones.toggled.connect(self.set_headphones)
        form.addRow("Headphones", self.headphones)
        self.backlight = QtWidgets.QProgressBar()
        self.backlight.setRange(0, 100)
        self.backlight.setFormat("%p%")
        form.addRow("Backlight", self.backlight)
        self.speaker = QtWidgets.QLabel("?")
        form.addRow("Speaker", self.speaker)
        self.lcd = QtWidgets.QLabel("?")
        form.addRow("LCD", self.lcd)
        form.addRow("Sound", QtWidgets.QLabel(audio))
        grid.addWidget(box)

        # -- the console ----------------------------------------------------
        box = QtWidgets.QGroupBox("Console")
        lay = QtWidgets.QVBoxLayout(box)
        self.log = QtWidgets.QPlainTextEdit(readOnly=True)
        self.log.setMaximumBlockCount(5000)
        font = QtGui.QFontDatabase.systemFont(QtGui.QFontDatabase.SystemFont.FixedFont)
        self.log.setFont(font)
        self.log.setMinimumHeight(160)
        self.term = Terminal(self.log)
        self.input = QtWidgets.QLineEdit(placeholderText="A command for the Chumby's shell (Enter sends, even empty)")
        self.input.setFont(font)
        enter = QtWidgets.QPushButton("\u23ce Enter")
        enter.setToolTip("Send the line to the console; with none, just Enter")
        enter.clicked.connect(self.on_input)
        self.open_term = QtWidgets.QPushButton("Open terminal")
        self.open_term.setToolTip("The console in your own terminal app, for full-screen "
                                  "programs (top, vi); Ctrl-] closes it")
        self.open_term.clicked.connect(self.terminal)
        row = QtWidgets.QHBoxLayout()
        row.addWidget(self.input, 1)
        row.addWidget(enter)
        row.addWidget(self.open_term)
        lay.addWidget(self.log)
        lay.addLayout(row)
        # A click in the console's output types into its input line.
        self.log.viewport().installEventFilter(self)
        self.activated = False
        grid.addWidget(box, 1)
        self.console = None
        try:
            self.console = Console(con_path)
            self.console.received.connect(self.on_console)
            self.input.returnPressed.connect(self.on_input)
        except OSError:
            box.setEnabled(False)

        # -- the toolbar ----------------------------------------------------
        tb = self.addToolBar("Machine")
        tb.setMovable(False)
        self.act(tb, "Screenshot", self.screenshot, "Ctrl+S")
        self.pause = self.act(tb, "Pause", self.toggle_pause, "Ctrl+P")
        self.pause.setCheckable(True)
        tb.setToolButtonStyle(QtCore.Qt.ToolButtonStyle.ToolButtonTextBesideIcon)
        self.act(tb, "Reset", lambda: self.qmp.cmd("system_reset"), None)
        self.act(tb, "Save state", self.savevm, None)
        self.act(tb, "Restore state", self.loadvm, None)
        self.act(tb, "Quit", self.close, "Ctrl+Q")

        self.status = self.statusBar()
        self.status.showMessage(f"Window: {display}; no network")
        self.runstate = QtWidgets.QLabel()
        self.status.addPermanentWidget(self.runstate)
        st = self.try_cmd(self.qmp.cmd, "query-status") or {}
        self.show_running(st.get("running", True))

        self.timer = QtCore.QTimer(self, interval=50, timeout=self.poll)
        self.timer.start()
        self.refresh_outputs()
        self.read_tilt()
        if mac_motion and self.has(*PROP_ACCEL) and self.follow.parent():
            self.follow.setChecked(True)

    # -- helpers -------------------------------------------------------------
    def slider(self, lo, hi, v):
        s = QtWidgets.QSlider(QtCore.Qt.Orientation.Horizontal)
        s.setRange(lo, hi)
        s.setValue(v)
        return s

    def act(self, tb, text, fn, key):
        a = QtGui.QAction(text, self)
        if key:
            a.setShortcut(QtGui.QKeySequence(key))
        a.triggered.connect(fn)
        tb.addAction(a)
        return a

    def try_cmd(self, fn, *a, **kw):
        try:
            return fn(*a, **kw)
        except Exception as e:  # QMP errors become a status message
            self.status.showMessage(str(e), 5000)
            return None

    # -- inputs ----------------------------------------------------------------
    def set_button(self, down):
        self.try_cmd(self.qmp.qom_set, "/machine", PROP_BUTTON, down)

    def keyPressEvent(self, e):
        if e.key() == QtCore.Qt.Key.Key_Space and not e.isAutoRepeat() and self.button.isEnabled():
            self.button.setDown(True)
            self.set_button(True)
        else:
            super().keyPressEvent(e)

    def keyReleaseEvent(self, e):
        if e.key() == QtCore.Qt.Key.Key_Space and not e.isAutoRepeat() and self.button.isEnabled():
            self.button.setDown(False)
            self.set_button(False)
        else:
            super().keyReleaseEvent(e)

    def set_headphones(self, on):
        self.try_cmd(self.qmp.qom_set, "/machine", PROP_HEADPHONES, on)

    def pose(self, pitch, roll):
        self.pitch.setValue(pitch)
        self.roll.setValue(roll)

    def gravity(self):
        """Gravity along the accelerometer's axes, in milli-g, from the
        sliders: upright and still is the machine's default, +1 g on Z."""
        p = math.radians(self.pitch.value())
        r = math.radians(self.roll.value())
        x = 1000 * math.sin(r) * math.cos(p)
        y = 1000 * math.sin(p)
        z = 1000 * math.cos(r) * math.cos(p)
        return [round(x), round(y), round(z)]

    def read_tilt(self):
        """Starts the sliders from the machine's acceleration."""
        if not self.has(*PROP_ACCEL):
            self.gread.setText("no accelerometer")
            return
        g = [self.try_cmd(self.qmp.qom_get, "/machine", a) or 0 for a in PROP_ACCEL]
        x, y, z = (max(-1.0, min(1.0, v / 1000)) for v in g)
        pitch = math.degrees(math.asin(y))
        roll = math.degrees(math.atan2(x, z)) if (x or z) else 0
        for sl, v in ((self.pitch, pitch), (self.roll, roll)):
            sl.blockSignals(True)
            sl.setValue(round(v))
            sl.blockSignals(False)
        self.gread.setText("x %+5d  y %+5d  z %+5d mg" % tuple(g))

    def send_tilt(self, *_):
        self.write_accel(self.gravity())

    def write_accel(self, g):
        self.gread.setText("x %+5d  y %+5d  z %+5d mg" % tuple(g))
        if not self.has(*PROP_ACCEL):
            return
        for prop, v in zip(PROP_ACCEL, g):
            self.try_cmd(self.qmp.qom_set, "/machine", prop, v)

    def set_follow(self, on):
        for w in (self.pitch, self.roll):
            w.setEnabled(not on)
        if on and not self.motion:
            self.motion = mac_motion.MotionSensor(self.on_motion)
            if not self.motion.ok:
                self.status.showMessage("This Mac's motion sensor didn't start", 5000)
        elif not on and self.motion:
            self.motion.stop()
            self.motion = None
            self.send_tilt()

    def on_motion(self, x, y, z):
        # From the sensor's thread, 100 times a second: keep the latest.
        self.motion_g = (x, y, z)

    def follow_motion(self):
        """Sends the Mac's latest reading, at the panel's 20 Hz tick. The
        Mac lying flat reads -1 g on Z; the Chumby still reads +1 g."""
        if self.motion and self.motion_g:
            g = [round(-v * 1000) for v in self.motion_g]
            self.motion_g = None
            self.write_accel(g)

    def shake(self):
        base = self.gravity()
        steps = [(1800, 0), (-1800, 0), (1500, 300), (-1500, -300), (900, 0), (-900, 0), (0, 0)]

        def step(i=0):
            if i == len(steps):
                return
            dx, dy = steps[i]
            self.write_accel([base[0] + dx, base[1] + dy, base[2]])
            QtCore.QTimer.singleShot(60, lambda: step(i + 1))
        step()

    # -- outputs -------------------------------------------------------------
    def refresh_outputs(self):
        try:
            o = self.qmp.cmd(QUERY_OUTPUTS)
        except Exception:
            return
        self.show_outputs(o or {})

    def show_outputs(self, o):
        if "backlight" in o:
            v = o["backlight"]
            self.backlight.setValue(round(100 * v / 65535))
        if "speaker-mute" in o:
            self.speaker.setText("muted" if o["speaker-mute"] else "on")
        if "lcd-on" in o:
            self.lcd.setText("on" if o["lcd-on"] else "off")
        if "headphones" in o:
            self.headphones.blockSignals(True)
            self.headphones.setChecked(bool(o["headphones"]))
            self.headphones.blockSignals(False)

    def poll(self):
        self.follow_motion()
        changed = False
        while True:
            try:
                ev = self.events.get_nowait()
            except queue.Empty:
                break
            name = ev.get("event", "")
            if name in ("SHUTDOWN", "QMP_CLOSED"):
                self.close()
                return
            if name.startswith(EVENT_PREFIX):
                changed = True
            elif name == "STOP":
                self.show_running(False)
            elif name == "RESUME":
                self.show_running(True)
        if changed:
            self.refresh_outputs()

    # -- the console -----------------------------------------------------------
    def eventFilter(self, obj, ev):
        if ev.type() == QtCore.QEvent.Type.MouseButtonRelease and \
                not self.log.textCursor().hasSelection():
            self.input.setFocus()
        return False

    def on_console(self, text):
        # The stock firmware's init waits for Enter before it starts the
        # console's shell: give it one, once.
        if not self.activated and "press Enter to activate" in text:
            self.activated = True
            self.console.send("")
        self.term.write(text)

    def terminal(self):
        """Opens the desktop's terminal on the console, through chumby-term."""
        if not self.console:
            return
        cmd = [sys.executable, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                            "chumby-term"), self.console.term_path]
        try:
            open_terminal(cmd)
        except OSError as e:
            self.status.showMessage(f"No terminal to open: {e}", 8000)

    def on_input(self):
        if self.console:
            self.console.send(self.input.text())
        self.input.clear()
        self.input.setFocus()

    # -- the machine -------------------------------------------------------------
    def screenshot(self):
        path, _ = QtWidgets.QFileDialog.getSaveFileName(
            self, "Save screenshot", os.path.expanduser("~/chumby.png"), "PNG (*.png)")
        if path:
            self.try_cmd(self.qmp.cmd, "screendump", filename=path, format="png")

    def toggle_pause(self, on):
        self.try_cmd(self.qmp.cmd, "stop" if on else "cont")
        # The STOP or RESUME event confirms it; show it at once meanwhile.
        self.show_running(not on)

    def show_running(self, running):
        """Shows whether the machine runs: the Pause/Resume button, the
        banner, the title and the status bar."""
        style = self.style()
        sp = QtWidgets.QStyle.StandardPixmap
        self.pause.setChecked(not running)
        self.pause.setText("Pause" if running else "Resume")
        self.pause.setIcon(style.standardIcon(sp.SP_MediaPause if running
                                              else sp.SP_MediaPlay))
        self.pause.setToolTip("Stop the Chumby (Ctrl+P)" if running
                              else "Carry on (Ctrl+P)")
        self.banner.setVisible(not running)
        self.setWindowTitle("Chumby" if running else "Chumby (paused)")
        self.runstate.setText("\u25b6 Running" if running else "\u23f8 Paused")
        self.runstate.setStyleSheet("color: #2e8b57; font-weight: bold;" if running
                                    else "color: #c47f00; font-weight: bold;")

    def hmp(self, line):
        r = self.try_cmd(self.qmp.cmd, "human-monitor-command", **{"command-line": line})
        if r:
            self.status.showMessage(r.strip(), 8000)

    def savevm(self):
        self.hmp("savevm " + self.snapshot)
        # One saved state: the other clock's is stale now.
        self.try_cmd(self.qmp.cmd, "human-monitor-command",
                     **{"command-line": "delvm " + self.other})
        self.status.showMessage("Saved", 4000)

    def loadvm(self):
        self.hmp("loadvm " + self.snapshot)

    def closeEvent(self, e):
        self.timer.stop()
        if self.motion:
            self.motion.stop()
        if self.proc.poll() is None and not self.qmp.closed:
            try:
                self.qmp.cmd("quit")
            except Exception:
                pass
        super().closeEvent(e)


def _run(*args):
    import subprocess
    try:
        r = subprocess.run(args, capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.SubprocessError):
        return ""
    return r.stdout.strip() if r.returncode == 0 else ""


def _gsetting(schema, key):
    v = _run("gsettings", "get", schema, key)
    return v.strip("'\"") if v and not v.startswith("@") else ""


def default_terminal():
    """The desktop's default terminal, as the argument list that runs a
    command in it (the command follows), or None. In order: $TERMINAL;
    xdg-terminal-exec (freedesktop's, which KDE Plasma 6 and GNOME use);
    the desktop's own setting (KDE's kdeglobals, GNOME's, Cinnamon's and
    MATE's gsettings, Xfce's exo); then the usual terminals."""
    import shutil
    if os.environ.get("TERMINAL") and shutil.which(os.environ["TERMINAL"]):
        return [os.environ["TERMINAL"], "-e"]
    if shutil.which("xdg-terminal-exec"):
        return ["xdg-terminal-exec"]
    desktop = os.environ.get("XDG_CURRENT_DESKTOP", "").upper().split(":")
    if "KDE" in desktop:
        for tool in ("kreadconfig6", "kreadconfig5"):
            app = _run(tool, "--group", "General", "--key", "TerminalApplication")
            if shutil.which(tool):
                app = app or "konsole"
                if shutil.which(app.split()[0]):
                    return app.split() + ["-e"]
    for names, schema in ((("GNOME", "UNITY", "BUDGIE"), "org.gnome.desktop.default-applications.terminal"),
                          (("X-CINNAMON", "CINNAMON"), "org.cinnamon.desktop.default-applications.terminal"),
                          (("MATE",), "org.mate.applications-terminal")):
        if set(names) & set(desktop):
            app = _gsetting(schema, "exec")
            if app and shutil.which(app):
                arg = _gsetting(schema, "exec-arg") or "-e"
                return [app, arg]
    if "XFCE" in desktop and shutil.which("exo-open"):
        return ["exo-open", "--launch", "TerminalEmulator"]
    for c in (["konsole", "-e"], ["ptyxis", "--"], ["kgx", "--"], ["gnome-terminal", "--"],
              ["xfce4-terminal", "-x"], ["x-terminal-emulator", "-e"], ["alacritty", "-e"],
              ["kitty"], ["foot"], ["wezterm", "start", "--"], ["xterm", "-e"]):
        if shutil.which(c[0]):
            return c
    return None


def open_terminal(cmd):
    """Runs cmd in a new window of the desktop's default terminal. On
    macOS, a .command file opened with open(1) goes to whichever app the
    user has made the default for shell scripts: Terminal, iTerm2...
    """
    import shlex
    import subprocess
    import tempfile
    if sys.platform == "darwin":
        fd, path = tempfile.mkstemp(prefix="chumby-console-", suffix=".command")
        with os.fdopen(fd, "w") as f:
            f.write("#!/bin/sh\nrm -f %s\nexec %s\n" % (
                shlex.quote(path), " ".join(shlex.quote(c) for c in cmd)))
        os.chmod(path, 0o700)
        subprocess.Popen(["open", path])
        return
    term = default_terminal()
    if not term:
        raise OSError("no terminal found; set $TERMINAL")
    if term[0] == "exo-open":
        term = term + [" ".join(shlex.quote(c) for c in cmd)]
        subprocess.Popen(term)
    else:
        subprocess.Popen(term + cmd)


def app():
    return QtWidgets.QApplication.instance() or QtWidgets.QApplication(["chumby-emu"])


def points_per_mm():
    """Logical pixels (points) per millimetre on the primary screen, or
    None if its physical size is missing or implausible."""
    screen = app().primaryScreen()
    if screen is None:
        return None
    mm = screen.physicalSize().width()
    pts = screen.geometry().width()
    if mm < 50 or pts <= 0:
        return None
    ppmm = pts / mm
    # 50 to 400 points per inch covers real displays; virtual ones often
    # report a made-up size.
    if not 50 / 25.4 <= ppmm <= 400 / 25.4:
        return None
    return ppmm


def run(qmp, events, con_path, proc, display, audio, **kw):
    a = app()
    a.setApplicationName("chumby-emu")
    a.setDesktopFileName("chumby-emu")
    w = Panel(qmp, events, con_path, proc, display, audio, **kw)
    w.resize(460, 720)
    w.show()
    a.exec()
