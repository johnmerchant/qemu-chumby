// SPDX-License-Identifier: GPL-2.0-or-later
//! A test hook: with CHUMBY_DESKTOP_TEST=FILE, the app runs FILE's lines
//! against its own window, through Qt's event delivery as typed keys and
//! mouse clicks go:
//!
//!     wait MS                 sleep
//!     waitfor TEXT [SECONDS]  wait for TEXT on the console (default 120 s)
//!     type TEXT               type on the keyboard (\n is Enter)
//!     key NAME                press and release a key: Return, F12, Escape...
//!     tap X Y                 press and release the pen at screen pixel X, Y
//!     drag X1 Y1 X2 Y2        press at one pixel, move to another, release
//!     click X Y               a mouse click at X, Y in the window
//!     grab FILE               the window's image to FILE (PNG)
//!     log FILE                the console's output so far to FILE
//!     title                   print the window's title
//!     console TEXT            type TEXT and Enter on the serial console
//!     call ACTION [ARGS]      what a control does: save, load, pause,
//!                             resume, reset, shake, tilt P R, headphones
//!                             on|off, button down|up, screenshot FILE
//!     quit                    close the window
//!
//! Each step's outcome is printed on stderr as `test: ...`.

use crate::machine::{qobject, CONSOLE_LOG, SCREEN_GEOMETRY};
use cxx_qt::CxxQtThread;
use std::path::PathBuf;
use std::sync::mpsc;
use std::time::{Duration, Instant};

type Qt = CxxQtThread<qobject::Machine>;

const SHIFT: i32 = 0x0200_0000;
const KEY_SHIFT: i32 = 0x0100_0020;

fn on_gui<R: Send + 'static>(qt: &Qt, f: impl FnOnce(std::pin::Pin<&mut qobject::Machine>) -> R + Send + 'static) -> Option<R> {
    let (tx, rx) = mpsc::channel();
    qt.queue(move |m| {
        let _ = tx.send(f(m));
    })
    .ok()?;
    rx.recv_timeout(Duration::from_secs(30)).ok()
}

/// A character as (Qt key, shifted).
fn char_key(c: char) -> Option<(i32, bool)> {
    Some(match c {
        'a'..='z' => (c.to_ascii_uppercase() as i32, false),
        'A'..='Z' => (c as i32, true),
        '0'..='9' | ' ' | '-' | '=' | '[' | ']' | '\\' | ';' | '\'' | '`' | ',' | '.' | '/' => (c as i32, false),
        '!' | '@' | '#' | '$' | '%' | '^' | '&' | '*' | '(' | ')' | '_' | '+' | '{' | '}' | '|'
        | ':' | '"' | '~' | '<' | '>' | '?' => (c as i32, true),
        '\n' => (0x0100_0004, false),
        '\t' => (0x0100_0001, false),
        _ => return None,
    })
}

fn named_key(name: &str) -> Option<i32> {
    Some(match name {
        "Return" | "Enter" => 0x0100_0004,
        "Escape" => 0x0100_0000,
        "Tab" => 0x0100_0001,
        "Backspace" => 0x0100_0003,
        "Up" => 0x0100_0013,
        "Down" => 0x0100_0015,
        "Left" => 0x0100_0012,
        "Right" => 0x0100_0014,
        "Space" => 0x20,
        f if f.starts_with('F') => 0x0100_0030 + f[1..].parse::<i32>().ok()? - 1,
        _ => return None,
    })
}

fn key(qt: &Qt, key: i32, mods: i32, text: String, press: bool) {
    on_gui(qt, move |_| qobject::send_key(key, mods, 0, &text, press));
    std::thread::sleep(Duration::from_millis(40));
}

fn to_window(x: f64, y: f64) -> (f64, f64) {
    let (ox, oy, s) = *SCREEN_GEOMETRY.lock().unwrap();
    (ox + (x + 0.5) * s, oy + (y + 0.5) * s)
}

fn mouse(qt: &Qt, x: f64, y: f64, kind: i32) {
    let (wx, wy) = to_window(x, y);
    on_gui(qt, move |_| qobject::send_mouse(wx, wy, kind));
}

pub fn run(script: PathBuf, qt: Qt) {
    let text = match std::fs::read_to_string(&script) {
        Ok(t) => t,
        Err(e) => {
            eprintln!("test: {}: {e}", script.display());
            return;
        }
    };
    std::thread::spawn(move || {
        for line in text.lines().map(str::trim).filter(|l| !l.is_empty() && !l.starts_with('#')) {
            let (cmd, rest) = line.split_once(' ').unwrap_or((line, ""));
            let nums: Vec<f64> = rest.split_whitespace().filter_map(|n| n.parse().ok()).collect();
            match cmd {
                "wait" => std::thread::sleep(Duration::from_millis(nums.first().copied().unwrap_or(1000.0) as u64)),
                "waitfor" => {
                    let (what, secs) = match rest.rsplit_once(' ') {
                        Some((w, s)) if s.parse::<u64>().is_ok() => (w.to_owned(), s.parse().unwrap()),
                        _ => (rest.to_owned(), 120),
                    };
                    let start = Instant::now();
                    let seen = loop {
                        let log = String::from_utf8_lossy(&CONSOLE_LOG.lock().unwrap()).into_owned();
                        if log.contains(&what) {
                            break true;
                        }
                        if start.elapsed() > Duration::from_secs(secs) {
                            break false;
                        }
                        std::thread::sleep(Duration::from_millis(200));
                    };
                    eprintln!("test: waitfor {what:?}: {}", if seen { "seen" } else { "TIMED OUT" });
                }
                "type" => {
                    let t = rest.replace("\\n", "\n");
                    for c in t.chars() {
                        let Some((k, shifted)) = char_key(c) else { continue };
                        let mods = if shifted { SHIFT } else { 0 };
                        let text = if c == '\n' { "\r".to_owned() } else { c.to_string() };
                        if shifted {
                            key(&qt, KEY_SHIFT, SHIFT, String::new(), true);
                        }
                        key(&qt, k, mods, text.clone(), true);
                        key(&qt, k, mods, text, false);
                        if shifted {
                            key(&qt, KEY_SHIFT, 0, String::new(), false);
                        }
                    }
                    eprintln!("test: typed {rest:?}");
                }
                "key" => match named_key(rest) {
                    Some(k) => {
                        key(&qt, k, 0, String::new(), true);
                        std::thread::sleep(Duration::from_millis(200));
                        key(&qt, k, 0, String::new(), false);
                        eprintln!("test: key {rest}");
                    }
                    None => eprintln!("test: no key {rest}"),
                },
                "tap" if nums.len() == 2 => {
                    mouse(&qt, nums[0], nums[1], 0);
                    std::thread::sleep(Duration::from_millis(150));
                    mouse(&qt, nums[0], nums[1], 2);
                    eprintln!("test: tapped {} {}", nums[0], nums[1]);
                }
                "drag" if nums.len() == 4 => {
                    mouse(&qt, nums[0], nums[1], 0);
                    for i in 1..=10 {
                        let f = i as f64 / 10.0;
                        std::thread::sleep(Duration::from_millis(30));
                        mouse(&qt, nums[0] + (nums[2] - nums[0]) * f, nums[1] + (nums[3] - nums[1]) * f, 1);
                    }
                    mouse(&qt, nums[2], nums[3], 2);
                    eprintln!("test: dragged");
                }
                "click" if nums.len() == 2 => {
                    let (x, y) = (nums[0], nums[1]);
                    on_gui(&qt, move |_| qobject::send_mouse(x, y, 0));
                    std::thread::sleep(Duration::from_millis(100));
                    on_gui(&qt, move |_| qobject::send_mouse(x, y, 2));
                    eprintln!("test: clicked {x} {y}");
                }
                "log" => {
                    let log = CONSOLE_LOG.lock().unwrap().clone();
                    let ok = std::fs::write(rest, log).is_ok();
                    eprintln!("test: log {rest}: {}", if ok { "saved" } else { "FAILED" });
                }
                "grab" => {
                    let path = rest.to_owned();
                    let ok = on_gui(&qt, move |_| qobject::grab_window(&path)).unwrap_or(false);
                    eprintln!("test: grab {rest}: {}", if ok { "saved" } else { "FAILED" });
                }
                "title" => {
                    let t = on_gui(&qt, |_| qobject::window_title()).unwrap_or_default();
                    eprintln!("test: title {t:?}");
                }
                "console" => {
                    let line = rest.to_owned();
                    on_gui(&qt, move |m| m.console_line(&line));
                    eprintln!("test: console {rest:?}");
                }
                "call" => {
                    let args: Vec<String> = rest.split_whitespace().map(str::to_owned).collect();
                    let shown = rest.to_owned();
                    on_gui(&qt, move |mut m| {
                        let a = |i: usize| args.get(i).map(String::as_str).unwrap_or("");
                        let num = |i: usize| a(i).parse::<f64>().unwrap_or(0.0);
                        match a(0) {
                            "save" => m.save_state(),
                            "load" => m.load_state(),
                            "pause" => m.pause(true),
                            "resume" => m.pause(false),
                            "reset" => m.reset(),
                            "shake" => m.shake(),
                            "tilt" => m.as_mut().tilt(num(1), num(2)),
                            "headphones" => m.plug_headphones(a(1) == "on"),
                            "button" => m.press_button(a(1) == "down"),
                            "screenshot" => m.screenshot(&cxx_qt_lib::QString::from(a(1))),
                            _ => eprintln!("test: no action {:?}", a(0)),
                        }
                    });
                    eprintln!("test: call {shown}");
                }
                "quit" => {
                    on_gui(&qt, |_| qobject::quit_app());
                    return;
                }
                _ => eprintln!("test: unknown step {line:?}"),
            }
        }
    });
}
