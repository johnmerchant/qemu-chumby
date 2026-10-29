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
import socket
import threading

try:
    from PySide6 import QtCore, QtGui, QtWidgets
except ImportError:  # pragma: no cover
    from PyQt6 import QtCore, QtGui, QtWidgets

# The machine's control surface (docs/system/arm/chumby-classic.rst,
# "Control surface"). Properties are on /machine.
PROP_BUTTON = "button"
PROP_HEADPHONES = "headphones"
PROP_ACCEL = ("accel-x", "accel-y", "accel-z")     # milli-g
QUERY_OUTPUTS = "query-chumby-state"
EVENT_PREFIX = "CHUMBY_"


class Console(QtCore.QObject):
    """The Chumby's console (UART1) on a unix socket."""
    received = QtCore.Signal(str) if hasattr(QtCore, "Signal") else QtCore.pyqtSignal(str)

    def __init__(self, path):
        super().__init__()
        self.s = socket.socket(socket.AF_UNIX)
        self.s.connect(path)
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        while True:
            try:
                d = self.s.recv(4096)
            except OSError:
                return
            if not d:
                return
            self.received.emit(d.decode("utf-8", "replace").replace("\r", ""))

    def send(self, line):
        # The UART's receive FIFO holds 32 characters: pieces of 16, a few
        # milliseconds apart (README.md, "Console").
        data = (line + "\r").encode()

        def go():
            for i in range(0, len(data), 16):
                self.s.sendall(data[i:i + 16])
                threading.Event().wait(0.005)
        threading.Thread(target=go, daemon=True).start()


class Panel(QtWidgets.QMainWindow):
    def __init__(self, qmp, events, con_path, proc, display, audio):
        super().__init__()
        self.qmp, self.events, self.proc = qmp, events, proc
        self.setWindowTitle("Chumby")
        props = {p["name"] for p in qmp.cmd("qom-list", path="/machine")}
        self.has = lambda *names: all(n in props for n in names)

        central = QtWidgets.QWidget()
        self.setCentralWidget(central)
        grid = QtWidgets.QVBoxLayout(central)

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
        self.input = QtWidgets.QLineEdit(placeholderText="Type a command for the Chumby's shell, then Enter")
        self.input.setFont(font)
        lay.addWidget(self.log)
        lay.addWidget(self.input)
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
        self.act(tb, "Reset", lambda: self.qmp.cmd("system_reset"), None)
        self.act(tb, "Save state", self.savevm, None)
        self.act(tb, "Restore state", self.loadvm, None)
        self.act(tb, "Quit", self.close, "Ctrl+Q")

        self.status = self.statusBar()
        self.status.showMessage(f"Window: {display}; no network")

        self.timer = QtCore.QTimer(self, interval=50, timeout=self.poll)
        self.timer.start()
        self.refresh_outputs()
        self.read_tilt()

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
                self.pause.setChecked(True)
            elif name == "RESUME":
                self.pause.setChecked(False)
        if changed:
            self.refresh_outputs()

    # -- the console -----------------------------------------------------------
    def on_console(self, text):
        c = self.log.textCursor()
        c.movePosition(QtGui.QTextCursor.MoveOperation.End)
        c.insertText(text)
        self.log.setTextCursor(c)
        self.log.ensureCursorVisible()

    def on_input(self):
        self.console.send(self.input.text())
        self.input.clear()

    # -- the machine -------------------------------------------------------------
    def screenshot(self):
        path, _ = QtWidgets.QFileDialog.getSaveFileName(
            self, "Save screenshot", os.path.expanduser("~/chumby.png"), "PNG (*.png)")
        if path:
            self.try_cmd(self.qmp.cmd, "screendump", filename=path, format="png")

    def toggle_pause(self, on):
        self.try_cmd(self.qmp.cmd, "stop" if on else "cont")

    def hmp(self, line):
        r = self.try_cmd(self.qmp.cmd, "human-monitor-command", **{"command-line": line})
        if r:
            self.status.showMessage(r.strip(), 8000)

    def savevm(self):
        self.hmp("savevm chumby")

    def loadvm(self):
        self.hmp("loadvm chumby")

    def closeEvent(self, e):
        self.timer.stop()
        if self.proc.poll() is None and not self.qmp.closed:
            try:
                self.qmp.cmd("quit")
            except Exception:
                pass
        super().closeEvent(e)


def run(qmp, events, con_path, proc, display, audio):
    app = QtWidgets.QApplication.instance() or QtWidgets.QApplication(["chumby-emu"])
    app.setApplicationName("chumby-emu")
    app.setDesktopFileName("chumby-emu")
    w = Panel(qmp, events, con_path, proc, display, audio)
    w.resize(460, 720)
    w.show()
    app.exec()
