// SPDX-License-Identifier: GPL-2.0-or-later
//! chumby-desktop: the Chumby Classic as a Linux desktop app. QEMU runs
//! the machine with no window of its own; this app shows its screen
//! (over VNC on a private socket) in a Qt Quick window and drives it over
//! QMP: the pen, the keyboard, the top button, tilt and shake, the
//! headphones, the board's outputs, snapshots and the console.

mod console;
mod json;
mod keymap;
mod launch;
mod machine;
mod qmp;
mod rfb;
mod term;
mod test;

/// The app's id: its .desktop file's name and, on Wayland, the window's.
pub const APP_ID: &str = "io.github.johnmerchant.QemuChumby";

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let code = match launch::parse(&args) {
        Ok(launch::Mode::Help) => {
            print!("{}", launch::USAGE);
            0
        }
        Ok(launch::Mode::Console(tty)) => term::console_bridge(&tty),
        Ok(launch::Mode::Run(o)) => {
            let _ = machine::OPTIONS.set(o);
            let code = machine::qobject::run_app(APP_ID, env!("CARGO_PKG_VERSION"));
            // The window has gone: so does the machine.
            if let Some(s) = machine::SESSION.lock().unwrap().take() {
                s.stop(std::time::Duration::from_secs(1));
            }
            code
        }
        Err(e) => {
            eprintln!("chumby-desktop: {e}\n\n{}", launch::USAGE);
            2
        }
    };
    std::process::exit(code);
}
