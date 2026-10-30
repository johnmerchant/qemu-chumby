// SPDX-License-Identifier: GPL-2.0-or-later
//! The console in the desktop's own terminal app: finding that terminal,
//! and `chumby-desktop --console TTY`, which runs in it and joins it to
//! the console's pseudo-terminal (as frontend/chumby-term does).

use std::io::{self, Write};
use std::os::fd::AsRawFd;
use std::process::{Command, Stdio};

fn which(name: &str) -> bool {
    if name.contains('/') {
        return std::path::Path::new(name).is_file();
    }
    std::env::var_os("PATH")
        .map(|p| std::env::split_paths(&p).any(|d| d.join(name).is_file()))
        .unwrap_or(false)
}

fn output(cmd: &str, args: &[&str]) -> String {
    Command::new(cmd)
        .args(args)
        .stderr(Stdio::null())
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_owned())
        .unwrap_or_default()
}

fn gsetting(schema: &str, key: &str) -> String {
    let v = output("gsettings", &["get", schema, key]);
    if v.starts_with('@') {
        return String::new();
    }
    v.trim_matches(|c| c == '\'' || c == '"').to_owned()
}

/// The desktop's default terminal, as the argument list that runs a
/// command in it (the command follows). In order: $TERMINAL;
/// xdg-terminal-exec (freedesktop's, which KDE Plasma 6 and GNOME use);
/// the desktop's own setting (KDE's kdeglobals; GNOME's, Cinnamon's and
/// MATE's gsettings; Xfce's exo); then the usual terminals.
pub fn default_terminal() -> Option<Vec<String>> {
    let v = |a: &[&str]| Some(a.iter().map(|s| s.to_string()).collect());
    if let Ok(t) = std::env::var("TERMINAL") {
        if !t.is_empty() && which(&t) {
            return Some(vec![t, "-e".into()]);
        }
    }
    if which("xdg-terminal-exec") {
        return v(&["xdg-terminal-exec"]);
    }
    let desktop: Vec<String> = std::env::var("XDG_CURRENT_DESKTOP")
        .unwrap_or_default()
        .to_uppercase()
        .split(':')
        .map(str::to_owned)
        .collect();
    let on = |names: &[&str]| names.iter().any(|n| desktop.iter().any(|d| d == n));
    if on(&["KDE"]) {
        for tool in ["kreadconfig6", "kreadconfig5"] {
            if which(tool) {
                let mut app = output(tool, &["--group", "General", "--key", "TerminalApplication"]);
                if app.is_empty() {
                    app = "konsole".into();
                }
                let mut words: Vec<String> = app.split_whitespace().map(str::to_owned).collect();
                if which(&words[0]) {
                    words.push("-e".into());
                    return Some(words);
                }
            }
        }
    }
    for (names, schema) in [
        (&["GNOME", "UNITY", "BUDGIE"][..], "org.gnome.desktop.default-applications.terminal"),
        (&["X-CINNAMON", "CINNAMON"][..], "org.cinnamon.desktop.default-applications.terminal"),
        (&["MATE"][..], "org.mate.applications-terminal"),
    ] {
        if on(names) {
            let app = gsetting(schema, "exec");
            if !app.is_empty() && which(&app) {
                let mut arg = gsetting(schema, "exec-arg");
                if arg.is_empty() {
                    arg = "-e".into();
                }
                return Some(vec![app, arg]);
            }
        }
    }
    if on(&["XFCE"]) && which("exo-open") {
        return v(&["exo-open", "--launch", "TerminalEmulator"]);
    }
    for c in [
        &["konsole", "-e"][..],
        &["ptyxis", "--"],
        &["kgx", "--"],
        &["gnome-terminal", "--"],
        &["xfce4-terminal", "-x"],
        &["x-terminal-emulator", "-e"],
        &["alacritty", "-e"],
        &["kitty"],
        &["foot"],
        &["wezterm", "start", "--"],
        &["xterm", "-e"],
    ] {
        if which(c[0]) {
            return v(c);
        }
    }
    None
}

fn shell_quote(s: &str) -> String {
    if !s.is_empty() && s.bytes().all(|b| b.is_ascii_alphanumeric() || b"/._-:=+,".contains(&b)) {
        s.to_owned()
    } else {
        format!("'{}'", s.replace('\'', "'\\''"))
    }
}

/// Runs cmd in a new window of the desktop's default terminal.
pub fn open_terminal(cmd: &[String]) -> Result<(), String> {
    let mut term = default_terminal().ok_or("no terminal found; set $TERMINAL")?;
    if term[0] == "exo-open" {
        term.push(cmd.iter().map(|c| shell_quote(c)).collect::<Vec<_>>().join(" "));
    } else {
        term.extend(cmd.iter().cloned());
    }
    Command::new(&term[0])
        .args(&term[1..])
        .stdin(Stdio::null())
        .spawn()
        .map(|_| ())
        .map_err(|e| format!("{}: {e}", term[0]))
}

/// `--console TTY`: joins this terminal, in raw mode, to TTY. Ctrl-]
/// closes it.
pub fn console_bridge(tty: &str) -> i32 {
    const ESCAPE: u8 = 0x1d; // Ctrl-]
    let dev = match std::fs::OpenOptions::new().read(true).write(true).open(tty) {
        Ok(f) => f,
        Err(e) => {
            eprintln!("chumby-desktop: {tty}: {e}");
            return 1;
        }
    };
    // Raw, and what queued up while nobody was reading is dropped: the
    // console's early output, hours old perhaps.
    let _ = crate::console::set_raw(dev.as_raw_fd());
    let mut out = io::stdout();
    let _ = out.write_all(
        b"\x1b[H\x1b[2J\x1b]0;Chumby console\x07Chumby console: Ctrl-] closes this window.\r\n",
    );
    let _ = out.flush();
    let mut devw = &dev;
    let _ = devw.write_all(b"\r");
    let stdin = 0;
    let saved = crate::console::set_raw(stdin).ok();
    let mut buf = [0u8; 4096];
    loop {
        let mut fds = [
            libc::pollfd { fd: stdin, events: libc::POLLIN, revents: 0 },
            libc::pollfd { fd: dev.as_raw_fd(), events: libc::POLLIN, revents: 0 },
        ];
        if unsafe { libc::poll(fds.as_mut_ptr(), 2, -1) } < 0 {
            if io::Error::last_os_error().kind() == io::ErrorKind::Interrupted {
                continue;
            }
            break;
        }
        if fds[1].revents != 0 {
            let n = unsafe { libc::read(dev.as_raw_fd(), buf.as_mut_ptr().cast(), buf.len()) };
            if n <= 0 {
                let _ = out.write_all(b"\r\n[the Chumby has quit]\r\n");
                break;
            }
            let _ = out.write_all(&buf[..n as usize]);
            let _ = out.flush();
        }
        if fds[0].revents != 0 {
            let n = unsafe { libc::read(stdin, buf.as_mut_ptr().cast(), buf.len()) };
            if n <= 0 || buf[..n as usize].contains(&ESCAPE) {
                break;
            }
            let _ = devw.write_all(&buf[..n as usize]);
        }
    }
    if let Some(t) = saved {
        unsafe { libc::tcsetattr(stdin, libc::TCSADRAIN, &t) };
    }
    0
}
