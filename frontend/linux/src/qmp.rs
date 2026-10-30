// SPDX-License-Identifier: GPL-2.0-or-later
//! A QMP client: commands from any thread, replies to callbacks, events to
//! a handler, all from one reader thread.

use crate::json::Json;
use std::collections::VecDeque;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{mpsc, Arc, Mutex};
use std::time::{Duration, Instant};

pub type Reply = Box<dyn FnOnce(Result<Json, String>) + Send>;

pub struct Qmp {
    out: Mutex<UnixStream>,
    pending: Arc<Mutex<VecDeque<Option<Reply>>>>,
    closed: Arc<AtomicBool>,
}

impl Qmp {
    /// Connects to QEMU's QMP socket, waiting up to `wait` for it to open,
    /// and negotiates capabilities. `on_event` gets each event; `on_close`
    /// runs once when QEMU closes the connection.
    pub fn connect(
        path: &Path,
        wait: Duration,
        on_event: impl Fn(Json) + Send + 'static,
        on_close: impl FnOnce() + Send + 'static,
    ) -> Result<Arc<Qmp>, String> {
        let start = Instant::now();
        let stream = loop {
            match UnixStream::connect(path) {
                Ok(s) => break s,
                Err(e) if start.elapsed() > wait => {
                    return Err(format!("QEMU's QMP socket didn't open: {e}"))
                }
                Err(_) => std::thread::sleep(Duration::from_millis(50)),
            }
        };
        let mut rd = BufReader::new(stream.try_clone().map_err(|e| e.to_string())?);
        let mut line = String::new();
        rd.read_line(&mut line).map_err(|e| e.to_string())?; // the greeting
        let mut w = stream;
        w.write_all(b"{\"execute\":\"qmp_capabilities\"}\n").map_err(|e| e.to_string())?;
        loop {
            line.clear();
            if rd.read_line(&mut line).map_err(|e| e.to_string())? == 0 {
                return Err("QEMU closed QMP".into());
            }
            if let Ok(v) = Json::parse(line.trim()) {
                if v.get("return").is_some() {
                    break;
                }
                if let Some(e) = v.get("error") {
                    return Err(e.to_string());
                }
            }
        }
        let qmp = Arc::new(Qmp {
            out: Mutex::new(w),
            pending: Arc::new(Mutex::new(VecDeque::new())),
            closed: Arc::new(AtomicBool::new(false)),
        });
        let pending = qmp.pending.clone();
        let closed = qmp.closed.clone();
        std::thread::Builder::new()
            .name("qmp".into())
            .spawn(move || {
                let mut line = String::new();
                loop {
                    line.clear();
                    match rd.read_line(&mut line) {
                        Ok(0) | Err(_) => break,
                        Ok(_) => {}
                    }
                    let Ok(v) = Json::parse(line.trim()) else { continue };
                    if v.get("event").is_some() {
                        on_event(v);
                        continue;
                    }
                    let r = if let Some(r) = v.get("return") {
                        Ok(r.clone())
                    } else if let Some(e) = v.get("error") {
                        Err(e.get("desc").and_then(Json::as_str).unwrap_or("QMP error").to_owned())
                    } else {
                        continue;
                    };
                    let cb = pending.lock().unwrap().pop_front().flatten();
                    if let Some(cb) = cb {
                        cb(r);
                    }
                }
                closed.store(true, Ordering::SeqCst);
                for cb in pending.lock().unwrap().drain(..).flatten() {
                    cb(Err("the machine has quit".into()));
                }
                on_close();
            })
            .map_err(|e| e.to_string())?;
        Ok(qmp)
    }

    pub fn is_closed(&self) -> bool {
        self.closed.load(Ordering::SeqCst)
    }

    /// Sends a command; `reply`, if any, gets its result on the reader
    /// thread.
    pub fn send(&self, cmd: &str, args: Option<Json>, reply: Option<Reply>) {
        let mut msg = vec![("execute".to_owned(), Json::str(cmd))];
        if let Some(a) = args {
            msg.push(("arguments".to_owned(), a));
        }
        let mut text = Json::Obj(msg).to_string();
        text.push('\n');
        let mut out = self.out.lock().unwrap();
        if self.is_closed() {
            drop(out);
            if let Some(cb) = reply {
                cb(Err("the machine has quit".into()));
            }
            return;
        }
        // The reply comes in order: queue its callback before it can arrive.
        self.pending.lock().unwrap().push_back(reply);
        if out.write_all(text.as_bytes()).is_err() {
            // The reader thread fails the pending callbacks when it sees
            // the connection close.
        }
    }

    /// Sends a command and waits for its result. Not for the GUI thread.
    pub fn call(&self, cmd: &str, args: Option<Json>) -> Result<Json, String> {
        let (tx, rx) = mpsc::channel();
        self.send(cmd, args, Some(Box::new(move |r| {
            let _ = tx.send(r);
        })));
        rx.recv_timeout(Duration::from_secs(30))
            .unwrap_or_else(|_| Err("no reply from the machine".into()))
    }

    pub fn qom_set(&self, prop: &str, value: Json) {
        self.send(
            "qom-set",
            Some(Json::obj([
                ("path", Json::str("/machine")),
                ("property", Json::str(prop)),
                ("value", value),
            ])),
            None,
        );
    }

    pub fn input_events(&self, events: Vec<Json>) {
        self.send("input-send-event", Some(Json::obj([("events", Json::Arr(events))])), None);
    }
}

/// An `abs` move on an axis, for input-send-event.
pub fn abs_event(axis: &str, value: i64) -> Json {
    Json::obj([
        ("type", Json::str("abs")),
        ("data", Json::obj([("axis", Json::str(axis)), ("value", Json::from(value))])),
    ])
}

/// A pointer button event, for input-send-event.
pub fn btn_event(button: &str, down: bool) -> Json {
    Json::obj([
        ("type", Json::str("btn")),
        ("data", Json::obj([("button", Json::str(button)), ("down", Json::from(down))])),
    ])
}

/// A key event by QKeyCode name, for input-send-event.
pub fn key_event(qcode: &str, down: bool) -> Json {
    Json::obj([
        ("type", Json::str("key")),
        (
            "data",
            Json::obj([
                ("down", Json::from(down)),
                ("key", Json::obj([("type", Json::str("qcode")), ("data", Json::str(qcode))])),
            ]),
        ),
    ])
}
