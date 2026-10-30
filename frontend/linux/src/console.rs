// SPDX-License-Identifier: GPL-2.0-or-later
//! The Chumby's console (UART1) on QEMU's unix socket, served on a
//! pseudo-terminal of our own (`/dev/pts/3`), which any terminal program
//! opens like a serial port: what the Chumby prints goes there, and what
//! is typed there goes to the Chumby, paced for its UART.

use std::fs::File;
use std::io::{self, Read, Write};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::sync::mpsc;
use std::time::Duration;

pub struct Console {
    pub tty: String,
    to_guest: mpsc::Sender<Vec<u8>>,
    // The pty's slave end stays open here, raw, so that the device exists
    // while no terminal has it open.
    _slave: OwnedFd,
}

/// Puts a terminal in raw mode, dropping input queued on it.
pub fn set_raw(fd: i32) -> io::Result<libc::termios> {
    unsafe {
        let mut t: libc::termios = std::mem::zeroed();
        if libc::tcgetattr(fd, &mut t) != 0 {
            return Err(io::Error::last_os_error());
        }
        let saved = t;
        libc::cfmakeraw(&mut t);
        if libc::tcsetattr(fd, libc::TCSAFLUSH, &t) != 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(saved)
    }
}

impl Console {
    /// Connects to the console's socket and opens the pseudo-terminal.
    /// `output` sees what the Chumby prints.
    pub fn start(sock: &Path, output: impl Fn(&[u8]) + Send + 'static) -> io::Result<Console> {
        let s = UnixStream::connect(sock)?;
        let (mut master, mut slave) = (0, 0);
        if unsafe {
            libc::openpty(&mut master, &mut slave, std::ptr::null_mut(), std::ptr::null(), std::ptr::null())
        } != 0
        {
            return Err(io::Error::last_os_error());
        }
        let slave = unsafe { OwnedFd::from_raw_fd(slave) };
        let master = unsafe { File::from_raw_fd(master) };
        set_raw(slave.as_raw_fd())?;
        let tty = unsafe {
            let p = libc::ttyname(slave.as_raw_fd());
            if p.is_null() {
                return Err(io::Error::last_os_error());
            }
            std::ffi::CStr::from_ptr(p).to_string_lossy().into_owned()
        };
        // Output nobody reads is dropped rather than blocking the console.
        unsafe {
            let fl = libc::fcntl(master.as_raw_fd(), libc::F_GETFL);
            libc::fcntl(master.as_raw_fd(), libc::F_SETFL, fl | libc::O_NONBLOCK);
        }

        let (tx, rx) = mpsc::channel::<Vec<u8>>();

        // The Chumby to the pty (and to `output`).
        let mut from = s.try_clone()?;
        let mut to_pty = master.try_clone()?;
        let enter = tx.clone();
        std::thread::Builder::new().name("console-out".into()).spawn(move || {
            let mut buf = [0u8; 4096];
            let mut seen = Vec::new();
            let mut activated = false;
            loop {
                let n = match from.read(&mut buf) {
                    Ok(0) | Err(_) => return,
                    Ok(n) => n,
                };
                let _ = to_pty.write_all(&buf[..n]);
                output(&buf[..n]);
                // The stock firmware's init waits for Enter before it
                // starts the console's shell: give it one, once.
                if !activated {
                    seen.extend_from_slice(&buf[..n]);
                    if seen.len() > 400 {
                        seen.drain(..seen.len() - 200);
                    }
                    if seen.windows(23).any(|w| w == b"press Enter to activate") {
                        activated = true;
                        let _ = enter.send(b"\r".to_vec());
                    }
                }
            }
        })?;

        // To the Chumby: the UART's receive FIFO holds 32 characters, so
        // pieces of 16, a few milliseconds apart.
        let mut to = s;
        std::thread::Builder::new().name("console-in".into()).spawn(move || {
            for data in rx {
                for piece in data.chunks(16) {
                    if to.write_all(piece).is_err() {
                        return;
                    }
                    std::thread::sleep(Duration::from_millis(5));
                }
            }
        })?;

        // The pty to the Chumby.
        let from_pty = master;
        let typed = tx.clone();
        std::thread::Builder::new().name("console-tty".into()).spawn(move || {
            let fd = from_pty.as_raw_fd();
            let mut buf = [0u8; 1024];
            loop {
                let mut p = libc::pollfd { fd, events: libc::POLLIN, revents: 0 };
                if unsafe { libc::poll(&mut p, 1, -1) } < 0 {
                    if io::Error::last_os_error().kind() == io::ErrorKind::Interrupted {
                        continue;
                    }
                    return;
                }
                if p.revents & libc::POLLHUP != 0 && p.revents & libc::POLLIN == 0 {
                    // No terminal has the device open: wait for one.
                    std::thread::sleep(Duration::from_millis(200));
                    continue;
                }
                let n = unsafe { libc::read(fd, buf.as_mut_ptr().cast(), buf.len()) };
                if n > 0 && typed.send(buf[..n as usize].to_vec()).is_err() {
                    return;
                }
                if n < 0 {
                    let e = io::Error::last_os_error();
                    if e.kind() != io::ErrorKind::WouldBlock && e.kind() != io::ErrorKind::Interrupted {
                        std::thread::sleep(Duration::from_millis(200));
                    }
                }
            }
        })?;

        Ok(Console { tty, to_guest: tx, _slave: slave })
    }

    /// Types a line on the console, ending it with Enter (CR).
    pub fn send_line(&self, line: &str) {
        let mut v = line.as_bytes().to_vec();
        v.push(b'\r');
        let _ = self.to_guest.send(v);
    }
}
