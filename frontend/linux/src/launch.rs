// SPDX-License-Identifier: GPL-2.0-or-later
//! The command line, and starting QEMU: the same options as chumby-emu,
//! with the screen on a VNC socket of our own instead of QEMU's window.

use std::collections::VecDeque;
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

pub const USAGE: &str = "\
chumby-desktop: the Chumby Classic as a desktop app, on Linux.

    chumby-desktop [IMAGES]                a directory with zImage (and nand.img)
    chumby-desktop --kernel zImage [--nand nand.img]

With no images, the window offers to open some, and the ones opened
before. The emulated Chumby never has a network: QEMU runs with -nic none.

Options:
  --qemu PATH      qemu-system-arm with the chumby-classic machine (default:
                   beside this program, then the checkout's build/obj/,
                   then $PATH)
  --audio NAME     pipewire, pa, alsa, sdl, wav:FILE or none (default: the
                   sound server that is running)
  --write          write the NAND image (default: snapshot=on, so the image
                   is never changed)
  --state DIR      keep this Chumby's flash writes and saved state in DIR (a
                   qcow2 overlay of the NAND image); \"Save state\" saves
                   there, and the next start resumes from it. Needs qemu-img.
  --fast           -icount shift=auto,sleep=off: boot in seconds, but sound
                   comes in bursts: for scripts and tests
  --scale N        the screen's size, in logical pixels per Chumby pixel
                   (default: a real Chumby's screen, 71 x 53 mm)
  --console TTY    join this terminal to the console on TTY (what the
                   Console button runs in your terminal app)
  -- ARGS          passed to QEMU as they are

Keys, with the screen focused (click it): every key goes to the Chumby by
its place on the keyboard, whatever your layout, except these:
  F12              the top button (the machine's button-key)
  Ctrl+Shift+P     pause, resume
  Ctrl+Shift+S     screenshot
  Ctrl+Shift+T     the console in your terminal app
  Ctrl+Shift+B     show or hide the controls
  Ctrl+Shift+F     full screen
  Ctrl+Q           quit

Environment: CHUMBY_DESKTOP_TEST=FILE runs FILE's test steps against the
window (see src/test.rs; headless with QT_QPA_PLATFORM=offscreen), and
CHUMBY_DESKTOP_DEBUG_KEYS=1 prints each key and the QKeyCode it sends.
";

#[derive(Clone, Debug, Default)]
pub struct Options {
    pub kernel: Option<PathBuf>,
    pub nand: Option<PathBuf>,
    pub qemu: Option<PathBuf>,
    pub audio: Option<String>,
    pub write: bool,
    pub state: Option<PathBuf>,
    pub fast: bool,
    pub scale: Option<f64>,
    pub extra: Vec<String>,
    /// A test script (see test.rs), from $CHUMBY_DESKTOP_TEST.
    pub test_script: Option<PathBuf>,
}

pub enum Mode {
    Run(Options),
    Console(String),
    Help,
}

pub fn parse(args: &[String]) -> Result<Mode, String> {
    let mut o = Options::default();
    let mut images: Option<PathBuf> = None;
    let mut i = 0;
    let value = |i: &mut usize, name: &str| -> Result<String, String> {
        *i += 1;
        args.get(*i).cloned().ok_or(format!("{name} needs a value"))
    };
    while i < args.len() {
        let a = args[i].as_str();
        // --opt=value as well as --opt value
        let (name, inline) = match a.split_once('=') {
            Some((n, v)) if n.starts_with("--") => (n, Some(v.to_owned())),
            _ => (a, None),
        };
        let val = |i: &mut usize| inline.clone().map(Ok).unwrap_or_else(|| value(i, name));
        match name {
            "-h" | "--help" => return Ok(Mode::Help),
            "--kernel" => o.kernel = Some(val(&mut i)?.into()),
            "--nand" => o.nand = Some(val(&mut i)?.into()),
            "--qemu" => o.qemu = Some(val(&mut i)?.into()),
            "--audio" => o.audio = Some(val(&mut i)?),
            "--state" => o.state = Some(val(&mut i)?.into()),
            "--scale" => {
                let v = val(&mut i)?;
                o.scale = Some(v.parse().map_err(|_| format!("--scale {v}: not a number"))?)
            }
            "--console" => return Ok(Mode::Console(val(&mut i)?)),
            "--write" => o.write = true,
            "--fast" => o.fast = true,
            "--" => {
                o.extra = args[i + 1..].to_vec();
                break;
            }
            s if s.starts_with('-') => return Err(format!("unknown option {s}")),
            s if images.is_none() => images = Some(s.into()),
            s => return Err(format!("unexpected argument {s}")),
        }
        i += 1;
    }
    if let Some(dir) = images {
        o.kernel.get_or_insert(dir.join("zImage"));
        let nand = dir.join("nand.img");
        if o.nand.is_none() && nand.exists() {
            o.nand = Some(nand);
        }
    }
    for bad in ["-netdev", "-nic", "-net", "-display", "-vnc"] {
        if o.extra.iter().any(|a| a == bad) {
            return Err(format!("{bad} isn't allowed after --: the emulated Chumby has no network, and this app shows the screen"));
        }
    }
    o.test_script = std::env::var_os("CHUMBY_DESKTOP_TEST").map(PathBuf::from);
    Ok(Mode::Run(o))
}

fn executable(p: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    p.metadata().map(|m| m.is_file() && m.permissions().mode() & 0o111 != 0).unwrap_or(false)
}

fn on_path(name: &str) -> Option<PathBuf> {
    std::env::split_paths(&std::env::var_os("PATH")?).map(|d| d.join(name)).find(|p| executable(p))
}

pub fn find_qemu(given: Option<&Path>) -> Result<PathBuf, String> {
    if let Some(q) = given {
        return Ok(q.to_owned());
    }
    if let Ok(exe) = std::env::current_exe() {
        let dir = exe.parent().unwrap_or(Path::new("/"));
        // Beside this program, where install.sh puts it, or in the
        // checkout this was built in (frontend/linux/target/release/).
        for p in [
            dir.join("qemu-system-arm"),
            dir.join("../libexec/chumby-desktop/qemu-system-arm"),
            dir.join("../../../../build/obj/qemu-system-arm"),
        ] {
            if executable(&p) {
                return Ok(p);
            }
        }
    }
    on_path("qemu-system-arm")
        .ok_or_else(|| "no qemu-system-arm with the chumby-classic machine (--qemu)".to_owned())
}

fn probe(qemu: &Path, args: &[&str]) -> String {
    Command::new(qemu)
        .args(args)
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
        .unwrap_or_default()
}

/// The sound backend: as asked, or the sound server that is running.
pub fn pick_audio(qemu: &Path, asked: Option<&str>) -> String {
    if let Some(a) = asked {
        return a.to_owned();
    }
    let have = probe(qemu, &["-audiodev", "help"]);
    let have: Vec<&str> = have.split(|c: char| c.is_whitespace() || c == ',').collect();
    let run = std::env::var("XDG_RUNTIME_DIR").unwrap_or_default();
    let mut order = Vec::new();
    if !run.is_empty() && Path::new(&run).join("pipewire-0").exists() {
        order.push("pipewire");
    }
    if std::env::var_os("PULSE_SERVER").is_some()
        || (!run.is_empty() && Path::new(&run).join("pulse/native").exists())
    {
        order.push("pa");
    }
    order.extend(["pipewire", "pa", "alsa", "sdl"]);
    order.into_iter().find(|a| have.contains(a)).unwrap_or("none").to_owned()
}

/// The saved state's name says which clock it was saved with: a state
/// saved with -icount can't be loaded without it, nor the other way round.
pub fn snapshot_name(fast: bool) -> &'static str {
    if fast {
        "chumby-fast"
    } else {
        "chumby"
    }
}

fn find_qemu_img(qemu: &Path) -> Result<PathBuf, String> {
    let beside = qemu.parent().map(|d| d.join("qemu-img"));
    beside
        .filter(|p| executable(p))
        .or_else(|| on_path("qemu-img"))
        .ok_or_else(|| "--state needs qemu-img (from your QEMU, or a qemu-img/qemu-utils package)".into())
}

/// The state directory's qcow2 overlay of the NAND image, made on first
/// use, and the clock of the saved state it holds, if any.
fn state_overlay(qemu: &Path, nand: &Path, state: &Path) -> Result<(PathBuf, Option<bool>), String> {
    let qimg = find_qemu_img(qemu)?;
    std::fs::create_dir_all(state).map_err(|e| format!("{}: {e}", state.display()))?;
    let overlay = state.join("nand.qcow2");
    if !overlay.exists() {
        let nand = std::fs::canonicalize(nand).map_err(|e| format!("{}: {e}", nand.display()))?;
        let ok = Command::new(&qimg)
            .args(["create", "-q", "-f", "qcow2", "-b"])
            .arg(&nand)
            .args(["-F", "raw"])
            .arg(&overlay)
            .status()
            .map(|s| s.success())
            .unwrap_or(false);
        if !ok {
            return Err("qemu-img couldn't make the state's overlay".into());
        }
    }
    let list = Command::new(&qimg)
        .args(["snapshot", "-l", "-U"])
        .arg(&overlay)
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
        .unwrap_or_default();
    let words: Vec<&str> = list.split_whitespace().collect();
    for fast in [false, true] {
        if words.contains(&snapshot_name(fast)) {
            return Ok((overlay, Some(fast)));
        }
    }
    Ok((overlay, None))
}

/// A running QEMU and the sockets it serves.
pub struct Session {
    child: Mutex<Option<Child>>,
    pub dir: PathBuf,
    pub qmp: PathBuf,
    pub vnc: PathBuf,
    pub console: PathBuf,
    pub audio: String,
    pub fast: bool,
    pub state: Option<PathBuf>,
    /// QEMU's last lines on stderr (also passed on to ours).
    pub stderr: Arc<Mutex<VecDeque<String>>>,
}

fn runtime_dir() -> PathBuf {
    std::env::var_os("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .filter(|p| p.is_dir())
        .unwrap_or_else(std::env::temp_dir)
}

fn make_private_dir() -> Result<PathBuf, String> {
    use std::os::unix::fs::DirBuilderExt;
    let base = runtime_dir();
    for n in 0..1000 {
        let d = base.join(format!("chumby-{}-{n}", std::process::id()));
        match std::fs::DirBuilder::new().mode(0o700).create(&d) {
            Ok(()) => return Ok(d),
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(e) => return Err(format!("{}: {e}", d.display())),
        }
    }
    Err("no room for the machine's sockets".into())
}

impl Session {
    pub fn start(o: &Options) -> Result<Session, String> {
        let kernel = o.kernel.as_ref().ok_or("no kernel")?;
        if !kernel.is_file() {
            return Err(format!("{}: no such kernel", kernel.display()));
        }
        let qemu = find_qemu(o.qemu.as_deref())?;
        if !executable(&qemu) {
            return Err(format!("{}: not a program", qemu.display()));
        }
        let audio = pick_audio(&qemu, o.audio.as_deref());
        let dir = make_private_dir()?;
        let (qmp, vnc, console) = (dir.join("qmp"), dir.join("vnc"), dir.join("con"));
        let mut fast = o.fast;
        let mut machine = "chumby-classic".to_owned();
        let s = |p: &Path| p.display().to_string();
        let mut args: Vec<String> = vec![
            "-name".into(),
            "Chumby".into(),
            "-kernel".into(),
            s(kernel),
            "-qmp".into(),
            format!("unix:{},server=on,wait=off", s(&qmp)),
            "-serial".into(),
            format!("unix:{},server=on,wait=off", s(&console)),
            "-monitor".into(),
            "none".into(),
            // The emulated Chumby never has a network.
            "-nic".into(),
            "none".into(),
            "-display".into(),
            "none".into(),
            "-vnc".into(),
            format!("unix:{}", s(&vnc)),
        ];
        // QEMU's VNC server loads a keymap (en-us), which a QEMU run from
        // its build tree may lack (they're built separately); this client
        // sends no keys over VNC (they go over QMP), so an empty one does.
        let keymaps = dir.join("data/keymaps");
        if std::fs::create_dir_all(&keymaps).and_then(|_| std::fs::write(keymaps.join("en-us"), "")).is_ok() {
            args.extend(["-L".into(), s(&dir.join("data"))]);
        }
        let mut state = None;
        if let Some(nand) = &o.nand {
            if !nand.is_file() {
                let _ = std::fs::remove_dir_all(&dir);
                return Err(format!("{}: no such NAND image", nand.display()));
            }
            if let Some(st) = &o.state {
                let (overlay, saved) = state_overlay(&qemu, nand, st).inspect_err(|_| {
                    let _ = std::fs::remove_dir_all(&dir);
                })?;
                args.extend(["-drive".into(), format!("if=mtd,file={},format=qcow2", s(&overlay))]);
                if let Some(saved_fast) = saved {
                    if saved_fast != fast {
                        eprintln!(
                            "chumby-desktop: resuming the saved state {} --fast, as it was saved",
                            if saved_fast { "with" } else { "without" }
                        );
                        fast = saved_fast;
                    }
                    args.extend(["-loadvm".into(), snapshot_name(fast).into()]);
                }
                state = Some(st.clone());
            } else {
                let snap = if o.write { "" } else { ",snapshot=on" };
                args.extend(["-drive".into(), format!("if=mtd,file={},format=raw{snap}", s(nand))]);
            }
        }
        if audio != "none" {
            if let Some(path) = audio.strip_prefix("wav:") {
                args.extend(["-audiodev".into(), format!("wav,id=snd0,path={path}")]);
            } else {
                args.extend(["-audiodev".into(), format!("{audio},id=snd0")]);
            }
            if probe(&qemu, &["-M", "chumby-classic,help"]).contains("audiodev") {
                machine.push_str(",audiodev=snd0");
            }
        }
        if fast {
            args.extend(["-icount".into(), "shift=auto,sleep=off".into()]);
        }
        let mut command = vec![s(&qemu), "-M".into(), machine];
        command.extend(args);
        command.extend(o.extra.iter().cloned());
        eprintln!("chumby-desktop: {}", command.join(" "));

        let mut child = Command::new(&command[0])
            .args(&command[1..])
            .stdin(Stdio::null())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|e| {
                let _ = std::fs::remove_dir_all(&dir);
                format!("{}: {e}", command[0])
            })?;
        let stderr = Arc::new(Mutex::new(VecDeque::new()));
        if let Some(err) = child.stderr.take() {
            let tail = stderr.clone();
            std::thread::spawn(move || {
                for line in BufReader::new(err).lines().map_while(Result::ok) {
                    eprintln!("{line}");
                    let mut t = tail.lock().unwrap();
                    t.push_back(line);
                    if t.len() > 12 {
                        t.pop_front();
                    }
                }
            });
        }
        Ok(Session {
            child: Mutex::new(Some(child)),
            dir,
            qmp,
            vnc,
            console,
            audio,
            fast,
            state,
            stderr,
        })
    }

    /// The exit status, once QEMU has exited.
    pub fn exited(&self) -> Option<std::process::ExitStatus> {
        let mut c = self.child.lock().unwrap();
        match c.as_mut() {
            Some(ch) => ch.try_wait().ok().flatten(),
            None => None,
        }
    }

    /// Waits up to `grace` for QEMU to exit (after QMP `quit`), then
    /// kills it, and removes the sockets.
    pub fn stop(&self, grace: Duration) {
        let start = Instant::now();
        if let Some(mut ch) = self.child.lock().unwrap().take() {
            while ch.try_wait().ok().flatten().is_none() {
                if start.elapsed() > grace {
                    let _ = ch.kill();
                    let _ = ch.wait();
                    break;
                }
                std::thread::sleep(Duration::from_millis(20));
            }
        }
        let _ = std::fs::remove_dir_all(&self.dir);
    }

    pub fn stderr_tail(&self) -> String {
        self.stderr.lock().unwrap().iter().cloned().collect::<Vec<_>>().join("\n")
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        self.stop(Duration::ZERO);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(a: &[&str]) -> Vec<String> {
        a.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn command_line() {
        let Mode::Run(o) = parse(&args(&["--kernel", "k", "--fast", "--scale=2.5", "--", "-append", "x"])).unwrap()
        else {
            panic!()
        };
        assert_eq!(o.kernel.unwrap(), PathBuf::from("k"));
        assert!(o.fast);
        assert_eq!(o.scale, Some(2.5));
        assert_eq!(o.extra, args(&["-append", "x"]));
        assert!(parse(&args(&["--kernel", "k", "--", "-nic", "user"])).is_err());
        assert!(matches!(parse(&args(&["--console", "/dev/pts/3"])).unwrap(), Mode::Console(_)));
    }
}
