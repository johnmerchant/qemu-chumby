// SPDX-License-Identifier: GPL-2.0-or-later
//! The QML side's view of the Chumby: `Machine`, which starts QEMU and
//! drives it over QMP, and `ChumbyScreen`, which draws its screen.

#[cxx_qt::bridge]
pub mod qobject {
    unsafe extern "C++" {
        include!("cxx-qt-lib/qstring.h");
        type QString = cxx_qt_lib::QString;
        include!("cxx-qt-lib/qpainter.h");
        type QPainter = cxx_qt_lib::QPainter;
    }

    unsafe extern "C++" {
        include!(<QtQuick/QQuickPaintedItem>);
        type QQuickPaintedItem;
    }

    #[namespace = "chumby"]
    unsafe extern "C++" {
        include!("glue.h");
        fn run_app(app_id: &str, version: &str) -> i32;
        fn send_key(key: i32, modifiers: i32, scan_code: u32, text: &str, press: bool);
        fn send_mouse(x: f64, y: f64, kind: i32);
        fn grab_window(path: &str) -> bool;
        fn quit_app();
    }

    extern "RustQt" {
        #[qobject]
        #[qml_element]
        // idle (nothing running), starting, running, stopped (QEMU exited)
        #[qproperty(QString, phase)]
        #[qproperty(bool, paused)]
        #[qproperty(i32, backlight)]
        #[qproperty(bool, lcd_on, cxx_name = "lcdOn")]
        #[qproperty(bool, speaker_mute, cxx_name = "speakerMute")]
        #[qproperty(bool, headphones)]
        #[qproperty(bool, button_down, cxx_name = "buttonDown")]
        #[qproperty(bool, has_button, cxx_name = "hasButton")]
        #[qproperty(bool, has_accel, cxx_name = "hasAccel")]
        #[qproperty(bool, has_headphones, cxx_name = "hasHeadphones")]
        #[qproperty(i32, accel_x, cxx_name = "accelX")]
        #[qproperty(i32, accel_y, cxx_name = "accelY")]
        #[qproperty(i32, accel_z, cxx_name = "accelZ")]
        #[qproperty(f64, pitch)]
        #[qproperty(f64, roll)]
        #[qproperty(QString, console_tty, cxx_name = "consoleTty")]
        #[qproperty(QString, audio)]
        #[qproperty(QString, state_dir, cxx_name = "stateDir")]
        #[qproperty(QString, kernel)]
        #[qproperty(QString, nand)]
        #[qproperty(bool, fast)]
        #[qproperty(i32, screen_width, cxx_name = "screenWidth")]
        #[qproperty(i32, screen_height, cxx_name = "screenHeight")]
        #[qproperty(f64, scale)]
        #[qproperty(QString, exit_info, cxx_name = "exitInfo")]
        type Machine = super::MachineRust;

        /// A new frame is in rfb::FRAME.
        #[qsignal]
        #[cxx_name = "frameReady"]
        fn frame_ready(self: Pin<&mut Machine>);

        /// A passing message for the user.
        #[qsignal]
        fn notice(self: Pin<&mut Machine>, text: QString);

        /// Starts the machine given on the command line, if any.
        #[qinvokable]
        #[cxx_name = "startFromCommandLine"]
        fn start_from_command_line(self: Pin<&mut Machine>) -> bool;

        /// Starts a machine chosen in the window.
        #[qinvokable]
        fn start(
            self: Pin<&mut Machine>,
            kernel: &QString,
            nand: &QString,
            state: &QString,
            fast: bool,
            write: bool,
        );

        /// The pen, at (x, y) in screen pixels, down or up.
        #[qinvokable]
        fn pen(self: Pin<&mut Machine>, x: f64, y: f64, down: bool);

        /// A key, pressed or released; false if it has no QKeyCode.
        #[qinvokable]
        fn key(
            self: Pin<&mut Machine>,
            platform: &QString,
            scan_code: u32,
            key: i32,
            modifiers: i32,
            down: bool,
        ) -> bool;

        /// Releases the keys held down (when the screen loses the keyboard).
        #[qinvokable]
        #[cxx_name = "releaseKeys"]
        fn release_keys(self: Pin<&mut Machine>);

        #[qinvokable]
        #[cxx_name = "pressButton"]
        fn press_button(self: Pin<&mut Machine>, down: bool);

        #[qinvokable]
        #[cxx_name = "plugHeadphones"]
        fn plug_headphones(self: Pin<&mut Machine>, on: bool);

        /// Tilts the Chumby: degrees forward/back and left/right.
        #[qinvokable]
        fn tilt(self: Pin<&mut Machine>, pitch: f64, roll: f64);

        #[qinvokable]
        fn shake(self: Pin<&mut Machine>);

        /// Saves the screen as PNG at an absolute path.
        #[qinvokable]
        fn screenshot(self: Pin<&mut Machine>, path: &QString);

        #[qinvokable]
        fn pause(self: Pin<&mut Machine>, on: bool);

        #[qinvokable]
        fn reset(self: Pin<&mut Machine>);

        #[qinvokable]
        #[cxx_name = "saveState"]
        fn save_state(self: Pin<&mut Machine>);

        #[qinvokable]
        #[cxx_name = "loadState"]
        fn load_state(self: Pin<&mut Machine>);

        /// Opens the console in the desktop's terminal app.
        #[qinvokable]
        #[cxx_name = "openConsole"]
        fn open_console(self: Pin<&mut Machine>);

        /// Where the screen is in the window, for the test hooks.
        #[qinvokable]
        #[cxx_name = "setScreenGeometry"]
        fn set_screen_geometry(self: Pin<&mut Machine>, x: f64, y: f64, scale: f64);

        /// Quits QEMU and waits (briefly) for it to go.
        #[qinvokable]
        #[cxx_name = "powerOff"]
        fn power_off(self: Pin<&mut Machine>);
    }

    impl cxx_qt::Threading for Machine {}
    impl cxx_qt::Initialize for Machine {}

    extern "RustQt" {
        #[qobject]
        #[qml_element]
        #[base = QQuickPaintedItem]
        type ChumbyScreen = super::ChumbyScreenRust;

        #[qinvokable]
        #[cxx_override]
        unsafe fn paint(self: Pin<&mut ChumbyScreen>, painter: *mut QPainter);
    }

    // A constructor of our own: the default one passes a QObject parent,
    // which QQuickPaintedItem's constructor doesn't take.
    impl cxx_qt::Constructor<()> for ChumbyScreen {}
}

use crate::console::Console;
use crate::json::Json;
use crate::launch::{snapshot_name, Options, Session};
use crate::qmp::{self, Qmp};
use crate::{keymap, rfb};
use core::pin::Pin;
use cxx_qt::{CxxQtThread, CxxQtType, Threading};
use cxx_qt_lib::{QImageFormat, QRect, QString};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

/// The command line's options, set by main.
pub static OPTIONS: OnceLock<Options> = OnceLock::new();
/// The running session, for cleaning up on the way out.
pub static SESSION: Mutex<Option<Arc<Session>>> = Mutex::new(None);
/// Which start the threads belong to: a thread of an older one stops.
static GENERATION: AtomicU64 = AtomicU64::new(0);
static FRAME_PENDING: AtomicBool = AtomicBool::new(false);
/// The console's recent output, for the test hooks.
pub static CONSOLE_LOG: Mutex<Vec<u8>> = Mutex::new(Vec::new());
/// Where the screen is in the window: x, y, logical pixels per pixel.
pub static SCREEN_GEOMETRY: Mutex<(f64, f64, f64)> = Mutex::new((0.0, 0.0, 1.0));

type Qt = CxxQtThread<qobject::Machine>;

pub struct MachineRust {
    phase: QString,
    paused: bool,
    backlight: i32,
    lcd_on: bool,
    speaker_mute: bool,
    headphones: bool,
    button_down: bool,
    has_button: bool,
    has_accel: bool,
    has_headphones: bool,
    accel_x: i32,
    accel_y: i32,
    accel_z: i32,
    pitch: f64,
    roll: f64,
    console_tty: QString,
    audio: QString,
    state_dir: QString,
    kernel: QString,
    nand: QString,
    fast: bool,
    screen_width: i32,
    screen_height: i32,
    scale: f64,
    exit_info: QString,

    qmp: Option<Arc<Qmp>>,
    session: Option<Arc<Session>>,
    console: Option<Console>,
    pen_down: bool,
    held: Vec<&'static str>,
}

impl Default for MachineRust {
    fn default() -> Self {
        MachineRust {
            phase: QString::from("idle"),
            paused: false,
            backlight: 100,
            lcd_on: true,
            speaker_mute: false,
            headphones: false,
            button_down: false,
            has_button: false,
            has_accel: false,
            has_headphones: false,
            accel_x: 0,
            accel_y: 0,
            accel_z: 1000,
            pitch: 0.0,
            roll: 0.0,
            console_tty: QString::default(),
            audio: QString::default(),
            state_dir: QString::default(),
            kernel: QString::default(),
            nand: QString::default(),
            fast: false,
            screen_width: 320,
            screen_height: 240,
            scale: 0.0,
            exit_info: QString::default(),
            qmp: None,
            session: None,
            console: None,
            pen_down: false,
            held: Vec::new(),
        }
    }
}

fn current(gen: u64) -> bool {
    GENERATION.load(Ordering::SeqCst) == gen
}

/// Gravity along the accelerometer's axes, in milli-g: upright and still
/// is the machine's default, +1 g on Z.
fn gravity(pitch: f64, roll: f64) -> [i64; 3] {
    let (p, r) = (pitch.to_radians(), roll.to_radians());
    [
        (1000.0 * r.sin() * p.cos()).round() as i64,
        (1000.0 * p.sin()).round() as i64,
        (1000.0 * r.cos() * p.cos()).round() as i64,
    ]
}

fn set_accel(q: &Qmp, g: [i64; 3]) {
    for (prop, v) in ["accel-x", "accel-y", "accel-z"].iter().zip(g) {
        q.qom_set(prop, Json::from(v));
    }
}

impl cxx_qt::Initialize for qobject::Machine {
    fn initialize(mut self: Pin<&mut Self>) {
        if let Some(s) = OPTIONS.get().and_then(|o| o.scale) {
            self.as_mut().set_scale(s);
        }
    }
}

impl qobject::Machine {
    fn qmp(&self) -> Option<Arc<Qmp>> {
        self.rust().qmp.clone().filter(|q| !q.is_closed())
    }

    fn say(self: Pin<&mut Self>, text: impl AsRef<str>) {
        eprintln!("chumby-desktop: {}", text.as_ref());
        self.notice(QString::from(text.as_ref()));
    }

    pub fn start_from_command_line(self: Pin<&mut Self>) -> bool {
        let Some(o) = OPTIONS.get().cloned() else { return false };
        if let Some(script) = o.test_script.clone() {
            crate::test::run(script, self.qt_thread());
        }
        if o.kernel.is_none() {
            return false;
        }
        self.launch(o);
        true
    }

    pub fn start(
        self: Pin<&mut Self>,
        kernel: &QString,
        nand: &QString,
        state: &QString,
        fast: bool,
        write: bool,
    ) {
        let mut o = OPTIONS.get().cloned().unwrap_or_default();
        let path = |s: &QString| Some(s.to_string()).filter(|s| !s.is_empty()).map(Into::into);
        o.kernel = path(kernel);
        o.nand = path(nand);
        // A folder of images: its zImage, and its nand.img if it has one.
        if let Some(dir) = o.kernel.clone().filter(|k: &std::path::PathBuf| k.is_dir()) {
            o.kernel = Some(dir.join("zImage"));
            if o.nand.is_none() && dir.join("nand.img").is_file() {
                o.nand = Some(dir.join("nand.img"));
            }
        }
        o.state = path(state);
        o.fast = fast;
        o.write = write;
        self.launch(o);
    }

    fn launch(mut self: Pin<&mut Self>, o: Options) {
        self.as_mut().stop_session(Duration::from_secs(3));
        let gen = GENERATION.fetch_add(1, Ordering::SeqCst) + 1;
        let opt = |p: &Option<std::path::PathBuf>| {
            QString::from(p.as_ref().map(|p| p.display().to_string()).unwrap_or_default().as_str())
        };
        self.as_mut().set_kernel(opt(&o.kernel));
        self.as_mut().set_nand(opt(&o.nand));
        self.as_mut().set_state_dir(if o.nand.is_some() { opt(&o.state) } else { QString::default() });
        self.as_mut().set_fast(o.fast);
        self.as_mut().set_exit_info(QString::default());
        self.as_mut().set_console_tty(QString::default());
        self.as_mut().set_paused(false);
        self.as_mut().set_phase(QString::from("starting"));
        let qt = self.qt_thread();
        std::thread::spawn(move || boot(o, gen, qt));
    }

    fn stop_session(mut self: Pin<&mut Self>, grace: Duration) {
        GENERATION.fetch_add(1, Ordering::SeqCst);
        let q = self.as_mut().rust_mut().qmp.take();
        let s = self.as_mut().rust_mut().session.take();
        self.as_mut().rust_mut().console = None;
        self.as_mut().rust_mut().held.clear();
        self.as_mut().rust_mut().pen_down = false;
        if let Some(q) = q {
            if !q.is_closed() {
                q.send("quit", None, None);
            }
        }
        if let Some(s) = s {
            s.stop(grace);
        }
        *SESSION.lock().unwrap() = None;
    }

    pub fn power_off(mut self: Pin<&mut Self>) {
        self.as_mut().stop_session(Duration::from_secs(3));
        self.as_mut().set_phase(QString::from("idle"));
    }

    fn apply_outputs(mut self: Pin<&mut Self>, o: &Json) {
        if let Some(v) = o.get("backlight").and_then(Json::as_f64) {
            self.as_mut().set_backlight((100.0 * v / 65535.0).round() as i32);
        }
        if let Some(v) = o.get("lcd-on").and_then(Json::as_bool) {
            self.as_mut().set_lcd_on(v);
        }
        if let Some(v) = o.get("speaker-mute").and_then(Json::as_bool) {
            self.as_mut().set_speaker_mute(v);
        }
        if let Some(v) = o.get("headphones").and_then(Json::as_bool) {
            self.as_mut().set_headphones(v);
        }
        if let Some(v) = o.get("button").and_then(Json::as_bool) {
            self.as_mut().set_button_down(v);
        }
    }

    fn refresh_outputs(self: Pin<&mut Self>, gen: u64) {
        let Some(q) = self.qmp() else { return };
        let qt = self.qt_thread();
        q.send(
            "query-chumby-state",
            None,
            Some(Box::new(move |r| {
                if let Ok(o) = r {
                    let _ = qt.queue(move |m| {
                        if current(gen) {
                            m.apply_outputs(&o);
                        }
                    });
                }
            })),
        );
    }

    fn on_event(mut self: Pin<&mut Self>, gen: u64, ev: Json) {
        let name = ev.get("event").and_then(Json::as_str).unwrap_or("");
        match name {
            "STOP" => self.as_mut().set_paused(true),
            "RESUME" => self.as_mut().set_paused(false),
            n if n.starts_with("CHUMBY_") => self.refresh_outputs(gen),
            _ => {}
        }
    }

    pub fn pen(mut self: Pin<&mut Self>, x: f64, y: f64, down: bool) {
        let Some(q) = self.qmp() else { return };
        let (w, h) = (*self.screen_width() as f64, *self.screen_height() as f64);
        let axis = |v: f64, size: f64| ((v.clamp(0.0, size - 1.0) * 32767.0 / (size - 1.0)).round()) as i64;
        let mut events = vec![qmp::abs_event("x", axis(x, w)), qmp::abs_event("y", axis(y, h))];
        let was = self.rust().pen_down;
        if down != was {
            events.push(qmp::btn_event("left", down));
            self.as_mut().rust_mut().pen_down = down;
        } else if !down {
            return; // no hovering: a touchscreen sees the pen only when down
        }
        q.input_events(events);
    }

    pub fn key(
        mut self: Pin<&mut Self>,
        platform: &QString,
        scan_code: u32,
        key: i32,
        modifiers: i32,
        down: bool,
    ) -> bool {
        let code = keymap::qcode(&platform.to_string(), scan_code, key, modifiers);
        if std::env::var_os("CHUMBY_DESKTOP_DEBUG_KEYS").is_some() {
            eprintln!("key {platform} scan {scan_code} key {key:#x} mods {modifiers:#x} down {down}: {code:?}");
        }
        let Some(code) = code else { return false };
        let Some(q) = self.qmp() else { return true };
        let held = &mut self.as_mut().rust_mut().held;
        if down {
            if !held.contains(&code) {
                held.push(code);
            }
        } else {
            held.retain(|c| *c != code);
        }
        q.input_events(vec![qmp::key_event(code, down)]);
        true
    }

    pub fn release_keys(mut self: Pin<&mut Self>) {
        let held = std::mem::take(&mut self.as_mut().rust_mut().held);
        if let Some(q) = self.qmp() {
            if !held.is_empty() {
                q.input_events(held.iter().map(|c| qmp::key_event(c, false)).collect());
            }
        }
    }

    pub fn press_button(mut self: Pin<&mut Self>, down: bool) {
        if let Some(q) = self.qmp() {
            q.qom_set("button", Json::from(down));
            self.as_mut().set_button_down(down);
        }
    }

    pub fn plug_headphones(mut self: Pin<&mut Self>, on: bool) {
        if let Some(q) = self.qmp() {
            q.qom_set("headphones", Json::from(on));
            self.as_mut().set_headphones(on);
        }
    }

    fn show_accel(mut self: Pin<&mut Self>, g: [i64; 3]) {
        self.as_mut().set_accel_x(g[0] as i32);
        self.as_mut().set_accel_y(g[1] as i32);
        self.as_mut().set_accel_z(g[2] as i32);
    }

    pub fn tilt(mut self: Pin<&mut Self>, pitch: f64, roll: f64) {
        self.as_mut().set_pitch(pitch);
        self.as_mut().set_roll(roll);
        let g = gravity(pitch, roll);
        self.as_mut().show_accel(g);
        if let Some(q) = self.qmp() {
            set_accel(&q, g);
        }
    }

    pub fn shake(self: Pin<&mut Self>) {
        let Some(q) = self.qmp() else { return };
        let base = gravity(*self.pitch(), *self.roll());
        std::thread::spawn(move || {
            for (dx, dy) in [(1800, 0), (-1800, 0), (1500, 300), (-1500, -300), (900, 0), (-900, 0), (0, 0)] {
                set_accel(&q, [base[0] + dx, base[1] + dy, base[2]]);
                std::thread::sleep(Duration::from_millis(60));
            }
        });
    }

    /// Runs a command; its error, or `done` on success, becomes a notice.
    fn command(self: Pin<&mut Self>, cmd: &str, args: Option<Json>, done: Option<String>) {
        let Some(q) = self.qmp() else { return };
        let qt = self.qt_thread();
        q.send(
            cmd,
            args,
            Some(Box::new(move |r| {
                let text = match r {
                    // HMP's errors come back as its output.
                    Ok(Json::Str(s)) if !s.trim().is_empty() => Some(s.trim().to_owned()),
                    Ok(_) => done,
                    Err(e) => Some(e),
                };
                if let Some(t) = text {
                    let _ = qt.queue(move |m| m.say(t));
                }
            })),
        );
    }

    fn hmp(self: Pin<&mut Self>, line: &str, done: Option<String>) {
        let args = Json::obj([("command-line", Json::str(line))]);
        self.command("human-monitor-command", Some(args), done);
    }

    pub fn screenshot(self: Pin<&mut Self>, path: &QString) {
        let path = path.to_string();
        let args = Json::obj([("filename", Json::str(path.as_str())), ("format", Json::str("png"))]);
        self.command("screendump", Some(args), Some(format!("Saved {path}")));
    }

    pub fn pause(mut self: Pin<&mut Self>, on: bool) {
        self.as_mut().command(if on { "stop" } else { "cont" }, None, None);
        // The STOP or RESUME event confirms it; show it at once meanwhile.
        self.as_mut().set_paused(on);
    }

    pub fn reset(self: Pin<&mut Self>) {
        self.command("system_reset", None, None);
    }

    pub fn save_state(mut self: Pin<&mut Self>) {
        if self.state_dir().is_empty() {
            self.say("Saving needs a state folder (--state)");
            return;
        }
        let fast = *self.fast();
        self.as_mut().hmp(&format!("savevm {}", snapshot_name(fast)), Some("Saved".into()));
        // One saved state: the other clock's is stale now.
        let args = Json::obj([("command-line", Json::str(format!("delvm {}", snapshot_name(!fast))))]);
        if let Some(q) = self.qmp() {
            q.send("human-monitor-command", Some(args), None);
        }
    }

    pub fn load_state(self: Pin<&mut Self>) {
        if self.state_dir().is_empty() {
            return;
        }
        let fast = *self.fast();
        self.hmp(&format!("loadvm {}", snapshot_name(fast)), Some("Restored".into()));
    }

    pub fn open_console(self: Pin<&mut Self>) {
        let tty = self.console_tty().to_string();
        if tty.is_empty() {
            return;
        }
        let exe = std::env::current_exe().map(|p| p.display().to_string()).unwrap_or("chumby-desktop".into());
        if let Err(e) = crate::term::open_terminal(&[exe, "--console".into(), tty]) {
            self.say(format!("No terminal to open: {e}"));
        }
    }

    /// Types a line on the serial console.
    pub fn console_line(&self, line: &str) {
        if let Some(c) = &self.rust().console {
            c.send_line(line);
        }
    }

    pub fn set_screen_geometry(self: Pin<&mut Self>, x: f64, y: f64, scale: f64) {
        *SCREEN_GEOMETRY.lock().unwrap() = (x, y, scale);
    }
}

/// Starts QEMU and connects to it, off the GUI thread.
fn boot(o: Options, gen: u64, qt: Qt) {
    let fail = |qt: &Qt, why: String| {
        let _ = qt.queue(move |mut m| {
            if current(gen) {
                m.as_mut().set_exit_info(QString::from(why.as_str()));
                m.as_mut().set_phase(QString::from("stopped"));
            }
        });
    };
    let sess = match Session::start(&o) {
        Ok(s) => Arc::new(s),
        Err(e) => return fail(&qt, e),
    };
    *SESSION.lock().unwrap() = Some(sess.clone());

    let ev_qt = qt.clone();
    let q = match Qmp::connect(
        &sess.qmp,
        Duration::from_secs(15),
        move |ev| {
            let _ = ev_qt.queue(move |m| {
                if current(gen) {
                    m.on_event(gen, ev);
                }
            });
        },
        || {},
    ) {
        Ok(q) => q,
        Err(e) => {
            std::thread::sleep(Duration::from_millis(300));
            let tail = sess.stderr_tail();
            sess.stop(Duration::ZERO);
            return fail(&qt, if tail.is_empty() { e } else { tail });
        }
    };

    // The console first, so that it sees the boot.
    let console = Console::start(&sess.console, |data| {
        let mut log = CONSOLE_LOG.lock().unwrap();
        log.extend_from_slice(data);
        if log.len() > 65536 {
            let cut = log.len() - 32768;
            log.drain(..cut);
        }
    });
    if let Err(e) = &console {
        eprintln!("chumby-desktop: no console: {e}");
    }

    let props: Vec<String> = q
        .call("qom-list", Some(Json::obj([("path", Json::str("/machine"))])))
        .map(|r| r.as_array().iter().filter_map(|p| p.get("name")?.as_str().map(str::to_owned)).collect())
        .unwrap_or_default();
    let has = |n: &str| props.iter().any(|p| p == n);
    let (has_button, has_headphones) = (has("button"), has("headphones"));
    let has_accel = has("accel-x") && has("accel-y") && has("accel-z");
    let mut accel = [0i64, 0, 1000];
    if has_accel {
        for (i, a) in ["accel-x", "accel-y", "accel-z"].iter().enumerate() {
            let args = Json::obj([("path", Json::str("/machine")), ("property", Json::str(*a))]);
            if let Some(v) = q.call("qom-get", Some(args)).ok().and_then(|v| v.as_f64()) {
                accel[i] = v as i64;
            }
        }
    }
    let running = q
        .call("query-status", None)
        .ok()
        .and_then(|s| s.get("running").and_then(Json::as_bool))
        .unwrap_or(true);
    let outputs = q.call("query-chumby-state", None).ok();

    let sq = q.clone();
    let ss = sess.clone();
    let _ = qt.queue(move |mut m| {
        if !current(gen) {
            return;
        }
        let audio = ss.audio.clone();
        m.as_mut().set_audio(QString::from(audio.as_str()));
        m.as_mut().set_fast(ss.fast);
        let state = ss.state.as_ref().map(|p| p.display().to_string()).unwrap_or_default();
        m.as_mut().set_state_dir(QString::from(state.as_str()));
        m.as_mut().rust_mut().qmp = Some(sq);
        m.as_mut().rust_mut().session = Some(ss);
        m.as_mut().set_has_button(has_button);
        m.as_mut().set_has_headphones(has_headphones);
        m.as_mut().set_has_accel(has_accel);
        // The tilt sliders start from the machine's acceleration.
        let [x, y, z] = accel.map(|v| (v as f64 / 1000.0).clamp(-1.0, 1.0));
        m.as_mut().set_pitch(y.asin().to_degrees().round());
        m.as_mut().set_roll(if x != 0.0 || z != 0.0 { x.atan2(z).to_degrees().round() } else { 0.0 });
        m.as_mut().show_accel(accel);
        if let Some(o) = &outputs {
            m.as_mut().apply_outputs(o);
        }
        m.as_mut().set_paused(!running);
        if let Ok(c) = console {
            m.as_mut().set_console_tty(QString::from(c.tty.as_str()));
            eprintln!("chumby-desktop: the console is {}", c.tty);
            m.as_mut().rust_mut().console = Some(c);
        }
        m.as_mut().set_phase(QString::from("running"));
    });

    // The screen.
    let vnc = sess.vnc.clone();
    let fqt = qt.clone();
    std::thread::Builder::new()
        .name("rfb".into())
        .spawn(move || {
            let r = rfb::run(&vnc, Duration::from_secs(15), || {
                if !current(gen) || FRAME_PENDING.swap(true, Ordering::SeqCst) {
                    return;
                }
                let _ = fqt.queue(move |mut m| {
                    FRAME_PENDING.store(false, Ordering::SeqCst);
                    let (w, h) = {
                        let f = rfb::FRAME.lock().unwrap();
                        (f.width as i32, f.height as i32)
                    };
                    if w > 0 && (w != *m.screen_width() || h != *m.screen_height()) {
                        m.as_mut().set_screen_width(w);
                        m.as_mut().set_screen_height(h);
                    }
                    m.frame_ready();
                });
            });
            if let Err(e) = r {
                if current(gen) {
                    eprintln!("chumby-desktop: the screen: {e}");
                }
            }
        })
        .ok();

    // QEMU's exit.
    loop {
        std::thread::sleep(Duration::from_millis(200));
        if !current(gen) {
            return;
        }
        if let Some(status) = sess.exited() {
            let tail = sess.stderr_tail();
            let why = match status.code() {
                Some(0) => String::new(),
                Some(c) => format!("QEMU exited with status {c}\n{tail}"),
                None => format!("QEMU was killed\n{tail}"),
            };
            let _ = qt.queue(move |mut m| {
                if current(gen) {
                    m.as_mut().stop_session(Duration::ZERO);
                    m.as_mut().set_exit_info(QString::from(why.trim()));
                    m.as_mut().set_phase(QString::from("stopped"));
                }
            });
            return;
        }
    }
}

/// The screen item: draws rfb::FRAME, one texel per Chumby pixel (QML
/// sets its textureSize, and smooth: false makes the scaling crisp).
#[derive(Default)]
pub struct ChumbyScreenRust;

impl cxx_qt::Constructor<()> for qobject::ChumbyScreen {
    type NewArguments = ();
    type BaseArguments = ();
    type InitializeArguments = ();

    fn route_arguments(_: ()) -> ((), (), ()) {
        ((), (), ())
    }

    fn new(_: ()) -> ChumbyScreenRust {
        ChumbyScreenRust
    }
}

extern "C" fn no_cleanup(_: *mut cxx_qt_lib::c_void) {}

impl qobject::ChumbyScreen {
    /// # Safety
    /// `painter` is the item's painter, valid during the call.
    pub unsafe fn paint(self: Pin<&mut Self>, painter: *mut qobject::QPainter) {
        let Some(painter) = painter.as_mut() else { return };
        let mut painter = Pin::new_unchecked(painter);
        let f = rfb::FRAME.lock().unwrap();
        if f.width == 0 || f.pixels.len() < (f.width * f.height) as usize {
            return;
        }
        let image = cxx_qt_lib::QImage::from_raw_parts(
            f.pixels.as_ptr().cast(),
            f.width as i32,
            f.height as i32,
            QImageFormat::Format_RGB32,
            no_cleanup,
            std::ptr::null_mut(),
        );
        painter.as_mut().draw_image(&QRect::new(0, 0, f.width as i32, f.height as i32), &image);
        drop(image);
    }
}
