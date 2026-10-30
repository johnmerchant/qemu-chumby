// SPDX-License-Identifier: GPL-2.0-or-later
//! A small RFB (VNC) client for QEMU's `-vnc unix:PATH`: no security,
//! 32-bit true colour, the raw encoding and desktop resizes. It only
//! watches the screen; the pen and keys go over QMP.

use std::io::{self, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::sync::Mutex;
use std::time::{Duration, Instant};

/// The latest screen: 0xffRRGGBB pixels (QImage::Format_RGB32), row by row.
pub struct Frame {
    pub width: u32,
    pub height: u32,
    pub pixels: Vec<u32>,
}

/// The one screen this process shows.
pub static FRAME: Mutex<Frame> = Mutex::new(Frame { width: 0, height: 0, pixels: Vec::new() });

const ENC_RAW: i32 = 0;
const ENC_DESKTOP_SIZE: i32 = -223;

fn u16be(b: &[u8]) -> u16 {
    u16::from_be_bytes([b[0], b[1]])
}

fn read_n(s: &mut UnixStream, n: usize) -> io::Result<Vec<u8>> {
    let mut v = vec![0; n];
    s.read_exact(&mut v)?;
    Ok(v)
}

fn update_request(s: &mut UnixStream, incremental: bool, w: u32, h: u32) -> io::Result<()> {
    let mut m = vec![3u8, incremental as u8, 0, 0, 0, 0];
    m.extend_from_slice(&(w as u16).to_be_bytes());
    m.extend_from_slice(&(h as u16).to_be_bytes());
    s.write_all(&m)
}

/// Connects to the VNC socket, waiting up to `wait` for it, and shows
/// the screen in FRAME until QEMU closes it. `changed` runs after each
/// update, on this thread.
pub fn run(path: &Path, wait: Duration, changed: impl Fn()) -> io::Result<()> {
    let start = Instant::now();
    let mut s = loop {
        match UnixStream::connect(path) {
            Ok(s) => break s,
            Err(e) if start.elapsed() > wait => return Err(e),
            Err(_) => std::thread::sleep(Duration::from_millis(50)),
        }
    };
    let bad = |what: &str| io::Error::new(io::ErrorKind::InvalidData, what.to_owned());

    // Version: 3.8 (QEMU speaks 3.3, 3.7 and 3.8).
    let v = read_n(&mut s, 12)?;
    if !v.starts_with(b"RFB ") {
        return Err(bad("not an RFB server"));
    }
    s.write_all(b"RFB 003.008\n")?;
    // Security: None.
    let n = read_n(&mut s, 1)?[0] as usize;
    if n == 0 {
        let len = u32::from_be_bytes(read_n(&mut s, 4)?.try_into().unwrap()) as usize;
        let why = read_n(&mut s, len)?;
        return Err(bad(&String::from_utf8_lossy(&why)));
    }
    let types = read_n(&mut s, n)?;
    if !types.contains(&1) {
        return Err(bad("the VNC server wants a password"));
    }
    s.write_all(&[1])?;
    if u32::from_be_bytes(read_n(&mut s, 4)?.try_into().unwrap()) != 0 {
        return Err(bad("VNC security handshake failed"));
    }
    // ClientInit (shared), ServerInit.
    s.write_all(&[1])?;
    let init = read_n(&mut s, 24)?;
    let (mut w, mut h) = (u16be(&init[0..]) as u32, u16be(&init[2..]) as u32);
    let name_len = u32::from_be_bytes(init[20..24].try_into().unwrap()) as usize;
    read_n(&mut s, name_len)?;

    // SetPixelFormat: 32 bpp, depth 24, little-endian, true colour,
    // 0x00RRGGBB in each pixel's little-endian word.
    let mut pf = vec![0u8, 0, 0, 0, 32, 24, 0, 1];
    pf.extend_from_slice(&255u16.to_be_bytes());
    pf.extend_from_slice(&255u16.to_be_bytes());
    pf.extend_from_slice(&255u16.to_be_bytes());
    pf.extend_from_slice(&[16, 8, 0, 0, 0, 0]);
    s.write_all(&pf)?;
    // SetEncodings: raw, and resizes.
    let encs = [ENC_RAW, ENC_DESKTOP_SIZE];
    let mut m = vec![2u8, 0];
    m.extend_from_slice(&(encs.len() as u16).to_be_bytes());
    for e in encs {
        m.extend_from_slice(&e.to_be_bytes());
    }
    s.write_all(&m)?;

    resize(w, h);
    update_request(&mut s, false, w, h)?;
    let mut row = Vec::new();
    loop {
        let t = read_n(&mut s, 1)?[0];
        match t {
            0 => {
                let hdr = read_n(&mut s, 3)?;
                let rects = u16be(&hdr[1..]);
                for _ in 0..rects {
                    let r = read_n(&mut s, 12)?;
                    let (x, y) = (u16be(&r[0..]) as usize, u16be(&r[2..]) as usize);
                    let (rw, rh) = (u16be(&r[4..]) as usize, u16be(&r[6..]) as usize);
                    let enc = i32::from_be_bytes(r[8..12].try_into().unwrap());
                    match enc {
                        ENC_RAW => {
                            row.resize(rw * 4, 0);
                            for j in 0..rh {
                                s.read_exact(&mut row)?;
                                let mut f = FRAME.lock().unwrap();
                                let fw = f.width as usize;
                                if y + j >= f.height as usize || x + rw > fw {
                                    continue;
                                }
                                let base = (y + j) * fw + x;
                                for (i, px) in row.chunks_exact(4).enumerate() {
                                    f.pixels[base + i] =
                                        0xff00_0000 | u32::from_le_bytes([px[0], px[1], px[2], 0]);
                                }
                            }
                        }
                        ENC_DESKTOP_SIZE => {
                            w = rw as u32;
                            h = rh as u32;
                            resize(w, h);
                        }
                        _ => return Err(bad("unexpected VNC encoding")),
                    }
                }
                changed();
                update_request(&mut s, true, w, h)?;
            }
            1 => {
                // SetColourMapEntries: not used with true colour.
                let hdr = read_n(&mut s, 5)?;
                read_n(&mut s, u16be(&hdr[3..]) as usize * 6)?;
            }
            2 => {} // Bell
            3 => {
                let hdr = read_n(&mut s, 7)?;
                let len = u32::from_be_bytes(hdr[3..7].try_into().unwrap()) as usize;
                read_n(&mut s, len)?;
            }
            _ => return Err(bad("unexpected VNC message")),
        }
    }
}

fn resize(w: u32, h: u32) {
    let mut f = FRAME.lock().unwrap();
    if f.width != w || f.height != h {
        f.width = w;
        f.height = h;
        f.pixels = vec![0xff00_0000; (w * h) as usize];
    }
}
