# qemu-chumby

A QEMU machine for the Chumby Classic: `qemu-system-arm -M chumby-classic`.

The Chumby Classic is a Wi-Fi internet appliance with a 320x240
touchscreen, built around the Freescale i.MX21 (an ARM926EJ-S). This
machine runs the Chumby's own software unmodified: the stock Linux 2.6.16
kernel boots from `-kernel`, mounts the stock root disk from an image of
the NAND flash, and starts the stock control panel, with a working
screen, touchscreen, console and flash.

It is a series of patches against a pinned QEMU release, written as QEMU
code (QOM devices under `hw/`, with a docs page), plus scripts to build
it, a desktop app (`chumby-emu`), a runner for scripts and tests
(`chumby-machine`) and a tool that makes the images it boots
(`chumby-image`).

An independent project, not affiliated with or endorsed by Chumby
Industries, Blue Octy or anyone holding rights in Chumby; "Chumby" is a
trademark of its owner, used only to say what hardware this models. See
[Legal](#legal).

## What is modelled

| Block | State |
| --- | --- |
| ARM926EJ-S, 64 MiB SDRAM | QEMU's ARM926 (identifying as r0p4, as the i.MX21's core) |
| AITC interrupt controller | Complete |
| GPT1-3 timers | Complete except input capture |
| UART1-4 | QEMU's i.MX UART; UART1 is the console |
| Crypto processor on UART3 | A made-up identity by default (GUID `C40BB1E0-0000-4000-8000-0E4000000001`, serial number `0000000000000000`, hardware version 3.8), settable. It holds no keys and refuses key and challenge requests |
| Clocks (CRM) and system control | Registers, PLLs locked at the boot loader's settings |
| GPIO ports A-F | Complete for the drivers |
| Keypad port | Used as GPIO: the data register reads the pins. The top button (`/dev/switch`) is row 0, headphone detect row 3, LCD power column 2, speaker mute column 4; no scan interrupts |
| CSPI1-3 | Complete except DMA |
| TSC2100 on CSPI3 | Touch conversions and PINTDAV (GPIO PE19); the pen is QEMU's absolute pointer. The audio codec too: playback and recording through `-audiodev`, at the rate its PLL makes |
| Sensor card on CSPI1 | Kionix KXP74 accelerometer (`/dev/accel`), settable over QMP, and the Atmel AT25080A DC ID EEPROM (`/dev/dcid`), selected through the card's decoder on GPIO PD28/PD27 |
| LCD controller | Background plane and graphic window (alpha, colour key), 16 bpp, as a QEMU display |
| NAND flash controller | 64 MiB small-page chip; reads, programs and erases, written back to the image |
| PWM | Sample FIFO, period and duty cycle; drives the backlight, which dims the screen |
| DMA controller | 16 channels: linear, 2D and FIFO transfers, repeat (chaining), bus error status |
| SSI1-2 and audio multiplexer | FIFOs, interrupts and DMA requests, as slaves of the codec |
| USB host | Three-port full-speed root hub with control, bulk, interrupt and isochronous transfers: QEMU's USB devices attach |
| Watchdog | Armed and serviced by the stock kernel; resets the machine, and reports why |
| RTC | Counts from the host's clock, with alarm and periodic interrupts (the stock kernel has no driver) |
| I2C controller | An empty bus (the stock kernel has no driver) |
| SDHC | Not modelled: the Chumby Classic has no card slot |

The patches:

| Patch | Adds |
| --- | --- |
| `0001` | `hw/intc/imx21_aitc.c` |
| `0002` | `hw/timer/imx21_gpt.c` |
| `0003` | `hw/misc/imx21_crm.c`, `imx21_pwm.c`, `imx21_usbotg.c` |
| `0004` | `hw/gpio/imx21_gpio.c` |
| `0005` | `hw/ssi/imx21_cspi.c` |
| `0006` | `hw/display/imx21_lcdc.c` |
| `0007` | `hw/block/imx21_nfc.c` |
| `0008` | `hw/input/tsc2100.c` |
| `0009` | `hw/char/chumby_cp.c` |
| `0010` | `hw/arm/fsl-imx21.c`, the SoC |
| `0011` | `hw/arm/chumby_classic.c`, the machine, and `docs/system/arm/chumby-classic.rst` |
| `0012` | `hw/input/imx21_kpp.c`, the keypad port, and the machine's top button |
| `0013`-`0015` | `hw/dma/imx21_dma.c`, `hw/audio/imx21_ssi.c` and `imx21_audmux.c`, and the TSC2100's sound |
| `0016`-`0021` | The PWM's output, the keypad port's outputs, LCD dimming, `qapi/chumby.json` and `hw/misc/chumby_io.c`: backlight, LCD power, speaker mute, headphones, the button's key |
| `0022` | The codec's clock from MCLK and its PLL |
| `0023`-`0024` | `hw/usb/hcd-imx21.c`, the USB host's transfers (replacing `imx21_usbotg.c`) |
| `0025`-`0031` | GPIO outputs, CSPI byte transfers, `hw/sensor/kxp74.c`, `hw/nvram/at25080a.c`, the settable identity and the sensor card on CSPI1 |
| `0032` | Recording opened only when the guest records |
| `0033` | A `scale` option for the Cocoa window |
| `0034`-`0035` | USB host fixes for Linux 5.9's `imx21-hcd` |
| `0036`-`0041` | The watchdog's reset source and grace period, `hw/rtc/imx21_rtc.c`, the I2C controller, and the interactive command line |
| `0042` | The codec clocking steadily when its timer runs late |

## Building

The patches apply to QEMU 11.1.2 (`qemu-release` pins the tarball and its
SHA-256).

With Nix, the flake's package is `qemu-system-arm` with the machine
for `aarch64-darwin` (Apple silicon), `x86_64-darwin`,
`aarch64-linux` and `x86_64-linux`. The same line builds and runs it on
each:

| Host | Build and run |
| --- | --- |
| macOS, Apple silicon | `nix run github:johnmerchant/qemu-chumby -- -M chumby-classic -kernel zImage -drive if=mtd,file=nand.img,format=raw -serial stdio` |
| Linux, x86_64 or aarch64 | `nix run github:johnmerchant/qemu-chumby -- -M chumby-classic -kernel zImage -drive if=mtd,file=nand.img,format=raw -serial stdio` |

`nix build github:johnmerchant/qemu-chumby` leaves it in
`result/bin/qemu-system-arm`. QEMU runs natively on each host (TCG; the
guest's ARM926 is emulated either way).

From a checkout, the build script also works in Nix's development shell:

    nix develop -c ./build

Without Nix, install the build dependencies and run `./build`. It
fetches and checks the QEMU tarball, applies the patches and builds only
`qemu-system-arm`, all in `./build` (or the directory given as its
argument); the binary is `build/obj/qemu-system-arm`.

| System | Packages |
| --- | --- |
| Debian, Ubuntu | `build-essential python3 python3-venv ninja-build pkg-config libglib2.0-dev libpixman-1-dev libpng-dev zlib1g-dev libfdt-dev curl xz-utils` |
| Fedora | `gcc make python3 ninja-build pkgconf glib2-devel pixman-devel libpng-devel zlib-devel libfdt-devel curl xz patch` |
| Arch | `base-devel python ninja pkgconf glib2 pixman libpng zlib dtc curl` |
| macOS (Homebrew) | `python ninja pkg-config glib pixman libpng` |

For a window and sound on Linux, add the GTK or SDL development
packages and those of your sound server (on Debian and Ubuntu:
`libgtk-3-dev libsdl2-dev libpipewire-0.3-dev libpulse-dev
libasound2-dev`); any desktop will do, KDE included, on X11 or Wayland.
On macOS the Cocoa window and CoreAudio are built in. VNC always is.
`tests/linux/run` builds and checks all this on Debian with KDE Plasma
6, in a container (see [Testing on Linux](#testing-on-linux)).

### Prebuilt binaries

CI (`.github/workflows/ci.yml`) builds `qemu-system-arm` with `./build`
for Linux x86_64 and aarch64 and macOS on Apple silicon, and boots each
on `tests/smoke/run`. Each commit on main publishes its builds on the
[`prebuilt`](https://github.com/johnmerchant/qemu-chumby/releases/tag/prebuilt)
prerelease, fetchable without a token:

    https://github.com/johnmerchant/qemu-chumby/releases/download/prebuilt/qemu-chumby-COMMIT-PLATFORM.tar.xz

and the same with `.sha256`, where COMMIT is the full commit ID and
PLATFORM is `linux-x86_64`, `linux-aarch64` or `macos-arm64`. The
tarball holds `qemu-system-arm`, `COPYING` and `RUNTIME`, which lists
what the binary needs: on Linux, glibc 2.39 or later (Ubuntu 24.04,
Debian 13) and glib, pixman, libpng and zlib (`libglib2.0-0t64
libpixman-1-0 libpng16-16t64 zlib1g`; a stock GitHub Ubuntu runner has
them); on macOS, the Homebrew packages it names (`glib pixman libpng`
and others the runner's Homebrew had, such as `gnutls`). The Linux builds have
no window or sound (VNC and `-display none` only), and the newest 100
commits' builds are kept.

## Images

The stock firmware needs two files from your own Chumby's flash backup:

- The kernel: the zImage at the start of the Kernel1 partition.
- A NAND image of the whole 64 MiB chip in `nanddump`'s layout: 131072
  records of 528 bytes, each a page's 512 data bytes followed by its 16
  spare (OOB) bytes, 69206016 bytes in all.

Programs and erases are written back to the NAND image, as the Chumby
writes its flash. Keep a copy, or use `snapshot=on` or `readonly=on` on
the drive to leave the image unchanged.

Other kernels boot too, with no NAND image or a blank one: a zImage with
its initramfs built in, or `-initrd` beside it, and `-append` for its
command line (the stock one names the NAND's root disk).

### chumby-image

`chumby-image` (in `image/`, a Rust crate with no dependencies) makes the
NAND image from a backup, the `mtdN-*.nanddump` files that `nanddump`
writes for each partition, and a settings directory:

    cargo build --release --manifest-path image/Cargo.toml
    image/target/release/chumby-image mkpsp PSPDIR psp.jffs2
    image/target/release/chumby-image mknand BACKUPDIR psp.jffs2 nand.img

or `nix run github:johnmerchant/qemu-chumby#image -- mkpsp ...`.
`mknand` keeps every partition as dumped except the settings partition
(PSP), which it replaces with `psp.jffs2`, and the update cache, which it
erases. PSPDIR is a fresh, factory-like settings set:

| File | Contents |
| --- | --- |
| `hostname` | `chumby` |
| `timezone`, `localtime` | `UTC`, and the root disk's own UTC zone file |
| `ts_settings` | `0,4095,4095,-4095,0`: the ADC's full range, which the emulated touchscreen reports against |
| `firsttime` | `0`, so the boot keeps that calibration rather than asking for one |
| `volume`, `mute`, `pan` | `50`, `0`, `0` |

The kernel is the zImage at the start of the Kernel1 partition; its
length is in its header (the word at offset 0x2c):

    head -c $((0x15ad34)) BACKUPDIR/mtd4-Kernel1.bin > zImage

Unlike the rest of this repository, `image/` is MIT-licensed (see
`image/LICENSE`).

## The desktop app: chumby-emu

`chumby-emu` runs the Chumby as a desktop app on macOS and Linux: QEMU's
window (Cocoa on macOS; GTK or SDL on Linux, on X11 or Wayland, KDE
and GNOME alike) with sound (CoreAudio; PipeWire, PulseAudio or ALSA,
whichever is running), and a control panel beside it for what the window
can't do:

- the top button (hold the panel's button or Space; F12 in QEMU's window)
- tilt and shake, for the accelerometer
- headphones in and out
- the Chumby's outputs: backlight level, speaker mute, LCD power
- screenshots, pause, reset, saving and restoring the machine's state
- the console, in your own terminal app (the desktop's default: Konsole,
  GNOME Terminal, Terminal.app, iTerm2...), or in any serial terminal
  program: the panel serves it on a pseudo-terminal, `/dev/ttys012` or
  `/dev/pts/3`, shown in its status bar (`tio /dev/ttys012`)

The mouse in the window is the pen. The emulated Chumby has no network:
QEMU always runs with `-nic none`.

    nix run github:johnmerchant/qemu-chumby#emu -- IMAGES

where IMAGES is a directory holding `zImage` and `nand.img` (see
[Images](#images)). The NAND image is attached with `snapshot=on`, so it
is never changed; `--write` keeps the Chumby's writes. From a checkout,
`./chumby-emu IMAGES` uses `build/obj/qemu-system-arm`; the panel needs
Python 3 with Qt 6 (PySide6 or PyQt6: `python3-pyside6.qtwidgets` on
Debian, `pyside6` on Arch, `pip install PySide6` elsewhere).
`chumby-emu --help` lists its options.

With `--state DIR`, the Chumby keeps its flash writes in DIR (a qcow2
overlay of the NAND image, which stays unchanged), and the panel's
"Save state" saves the running machine there: the next start resumes
from it in a fraction of a second instead of booting. `--fast` boots
in seconds by letting emulated time run ahead, which also makes sound
play fast and choppy; it is meant for scripts, and a saved state is
the quick way to start an interactive session.

### The Mac app: Chumby.app

On macOS there is a native app instead of QEMU's window and the Qt
panel: one window with the Chumby's screen, drawn crisp at a real
Chumby's size (71 x 53 mm on your display) or any other, keeping its
shape; an inspector beside it for the top button, tilt and shake, the
Mac's own motion sensor, headphones and the outputs; the machine's
commands in the toolbar and menus (pause, reset, screenshot, save and
restore state); and the serial console in a window of its own, also
served on a pseudo-terminal for other terminal programs. Sound plays
through CoreAudio as before. It builds with SwiftPM and the Command
Line Tools; Xcode is not needed:

    frontend/mac/build-app          # makes frontend/mac/build/Chumby.app

Once it is built, `chumby-emu` on macOS runs it in place of QEMU's window
and the Qt panel, with the same options (`--display`, `--no-panel` or
`CHUMBY_EMU_QT=1` keep the old way). The app takes them itself too, and
with none it opens a start window: an images folder or a kernel (and a
NAND image) to boot, a state folder, fast boot, extra QEMU arguments,
and the Chumbys started before:

    open frontend/mac/build/Chumby.app
    frontend/mac/build/Chumby.app/Contents/MacOS/Chumby --kernel zImage -- -append console=ttymxc0,115200

QEMU runs with `-display none -vnc unix:SOCKET`, in a private directory,
and the app draws the screen from that socket (raw RFB, which costs
nothing at 320x240). The mouse on the screen is the pen and keys typed
while the screen has the focus go to the Chumby, both as QMP
`input-send-event`s: keys by their place on the keyboard, as QEMU's own
Cocoa window sends them, so they reach the machine's USB keyboard
(plugged in on the first key, on machines with the `usb-keyboard`
option; give older ones `-device usb-kbd`). F12 is the top button.
Command shortcuts stay the Mac's. QEMU still always runs with
`-nic none`, and network options among the extra arguments are refused.

`swift test` in `frontend/mac` checks the RFB and QMP clients, the
console's terminal and the QEMU command line; with `CHUMBY_TEST_QEMU`
and `CHUMBY_TEST_KERNEL` set (a qemu-system-arm, and a kernel that boots
to a shell such as a sideload zImage), it also boots the machine and
checks that the screen over VNC matches `screendump`, that keys typed
with the Mac's key codes run in the screen's shell, and the top button.

## Scripts and tests: chumby-machine

`chumby-machine` runs the machine headless and drives it, for test
scenarios and scripts: Python 3's standard library only, as a command
line and as a module (`chumby_machine.py`). Each machine lives in a
directory of its own (`--dir DIR`, else `$CHUMBY_MACHINE_DIR`): QEMU's
process ID, its QMP and console sockets, and the console's log,
`console.log`. QEMU runs detached, so each command is a process of its
own and any number of them can drive one machine.

    chumby-machine --dir m start --kernel zImage --nand nand.img --stick stick.img
    chumby-machine --dir m wait log 'Please press Enter' 120
    chumby-machine --dir m wait screen 30
    chumby-machine --dir m tap 160 120
    chumby-machine --dir m shot screen.png
    chumby-machine --dir m exec 'uname -a'
    chumby-machine --dir m stop

| Command | What it does |
| --- | --- |
| `start --kernel ZIMAGE [OPTIONS] [-- QEMU OPTIONS]` | Starts the machine headless and returns once QMP answers. `--nand NAND` attaches a NAND image with `snapshot=on` (`--nand-write` to write it); `--psp DIR` boots a copy of it, kept in the machine's directory, whose settings partition holds DIR's files; `--initrd`, `--append` as QEMU's; `--stick IMG` a disk image as a USB stick (`usb-storage`), written as the guest writes it; `--fast` for `-icount shift=auto,sleep=off`; `--set PROP=VALUE` a machine property; `--qemu PATH` (else `$QEMU`, `build/obj/`, `PATH`) |
| `stop` | Quits QEMU (kills it if it doesn't answer) |
| `status` | Whether it runs, and the board's lines, as JSON; exits 1 if not running |
| `log [-f]` | The console's output |
| `wait log REGEX [SECS]` | Until the console's output matches; prints the match. Fails on a timeout or if QEMU exits first |
| `wait screen [SECS]` | Until the screen has stopped changing for half a second and isn't all black |
| `tap X Y [--hold MS]`, `down X Y`, `up` | The pen, in screen pixels |
| `button down\|up\|tap [MS]` | The top button |
| `headphones in\|out`, `accel X Y Z` | The headphone jack, the accelerometer (milli-g) |
| `shot OUT.png`, `pixel X Y` | The screen, or one pixel as `#rrggbb` |
| `compare [--min F] [--wait SECS] [--want RE] [--mask X,Y,W,H]... PICTURE...` | Which picture (a PNG, or a raw 320x240 RGB565 dump) the screen is most like, and the share of its pixels that match; with `--wait`, until the best one matches `--min` of them and its name matches RE |
| `type TEXT`, `exec [--timeout SECS] COMMAND` | Types on the console; runs a shell command there (a shell must be waiting on it) and exits with its status, printing its output |
| `powercut OUT.img` | The power cut: the machine stopped where it is, the stick image copied to OUT as it stands, QEMU killed |
| `mkfat DIR OUT.img [--size MB] [--label NAME]` | A stick image: an MBR and one FAT16 partition holding DIR's files (links followed), at least 64 MiB |

The module has the same as a `Machine` class (`Machine(DIR).start(...)`,
`.wait_log(...)`, `.tap(...)`, `.exec(...)`...), raising
`chumby_machine.Error`, plus the images' helpers: `mkfat`, `fat_files`
(a stick image's files, read back), `jffs2` (a directory as a JFFS2
image, byte for byte what `chumby-image mkpsp` makes) and `nand_with` (a
copy of a NAND image with partitions replaced). `chumby-ctl` shares its
QMP client. With Nix, `nix run github:johnmerchant/qemu-chumby#machine`
has QEMU built in.

The machine never gets a network: `chumby-machine` always runs QEMU with
`-nic none` and refuses `-netdev`, `-net` and `-nic` among the QEMU
options it is given.

## Testing on Linux

`tests/linux/run IMAGES` builds the machine on Debian 13 in a container
(Apple's `container`, Docker or Podman, on a Mac or on Linux) and checks
a KDE Plasma 6 desktop there, with KWin on X11 and as a Wayland
compositor: QEMU's GTK and SDL windows come up under KWin and show the
Chumby's screen, sound reaches PulseAudio, and chumby-emu's Qt panel
drives the machine. The checks run with no network.

`tests/smoke/run [QEMU]` needs no images: it boots the machine on a
kernel of a few instructions that writes to the console, and checks the
console, QMP, the screen dump, the button and the accelerometer through
chumby-machine. CI runs it on each build.

## Running

    qemu-system-arm -M chumby-classic -kernel zImage \
        -drive if=mtd,file=nand.img,format=raw \
        -serial stdio -qmp unix:qmp.sock,server=on,wait=off

UART1, the console, is on stdio: the kernel's messages, then a shell
once the first-run screens are done ("Please press Enter to activate
this console"). Without `-append`, the kernel gets the stock command
line for the first root disk.

The screen opens in a window (Cocoa on macOS, SDL or GTK on Linux); use
`-display none` to run headless or `-vnc :0` for VNC. In the window,
the mouse is the pen: click to touch.

By default emulated time follows the host's clock, as the real device
does. `-icount shift=auto,sleep=off` lets it run ahead while the Chumby
is idle, which boots to the control panel in a few seconds.

### Touch and screenshots

From QMP, `input-send-event` moves the pen (`abs` events on the `x` and
`y` axes, 0 to 32767 across the screen) and presses it (the `left`
button), and `screendump` writes the screen (`"format": "png"` for PNG).
`chumby-ctl` does both with screen pixels:

    ./chumby-ctl qmp.sock tap 278 22        # press and release at x=278, y=22
    ./chumby-ctl qmp.sock down 100 120      # press and hold
    ./chumby-ctl qmp.sock up
    ./chumby-ctl qmp.sock button tap        # press the top button for 300 ms
    ./chumby-ctl qmp.sock button down       # hold it
    ./chumby-ctl qmp.sock button up
    ./chumby-ctl qmp.sock shot screen.png
    ./chumby-ctl qmp.sock qmp '{"execute":"query-status"}'

From the human monitor (the window's, or one on a socket with
`-monitor unix:mon.sock,server=on,wait=off`), `screendump screen.png -f
png` writes a screenshot.

The touchscreen reports the ADC's full range across the screen. The
stock software maps it with the calibration in the settings partition
(`/psp/ts_settings`); `0,4095,4095,-4095,0` matches this machine.

## Control surface

What a harness driving the machine (`chumby-machine`, or a test runner
of your own) relies on. All of it is standard QEMU; nothing here is
specific to a client.

**Kernel.** `-kernel FILE`: a zImage, entered with ATAGs (memory 64 MiB
at 0xC0000000, the command line) as machine type 851, MX21ADS. `-append
TEXT` replaces the stock command line, which is otherwise
`console=ttyS0,38400 root=/dev/mtdblock5 rootfstype=cramfs init=/linuxrc
chumby_hwversion=3.8`.

**NAND.** `-drive if=mtd,file=PATH,format=raw`, optionally with
`snapshot=on` (writes go to a temporary overlay) or `readonly=on`
(writes stay in memory). The file must be exactly 69206016 bytes:
131072 pages, each stored as a 528-byte record, the page's 512 data bytes
then its 16 spare (OOB) bytes, page 0 first; 32 pages (16 KiB of data)
to an erase block. Any other size is refused at startup. Without a
drive the chip is blank (all 0xFF). Programs and erases are written to
the file as they happen.

**Console.** UART1 (the kernel's `ttyS0`, 38400 baud, which the
emulation ignores) is the first `-serial`: `-serial stdio`, `-serial
unix:PATH,server=on,wait=off` (connect and disconnect at will), or a
chardev with a log, e.g. `-chardev
socket,id=con,path=PATH,server=on,wait=off,logfile=console.log -serial
chardev:con`. The UART's receive FIFO holds 32 characters, and
characters beyond it are reported to the guest as overruns: send long
input in pieces of at most 16 characters, a few milliseconds apart.
Line endings to the shell are CR. UART2 and UART4 are the second and
fourth `-serial`; UART3 is the crypto processor.

**Touch.** QMP `input-send-event` with `abs` events on the `x` and `y`
axes and the `left` button, all in one command or across several:

    {"execute": "input-send-event", "arguments": {"events": [
      {"type": "abs", "data": {"axis": "x", "value": 28672}},
      {"type": "abs", "data": {"axis": "y", "value": 3000}},
      {"type": "btn", "data": {"button": "left", "down": true}}]}}

Axis values run from 0 to 32767 (QEMU's absolute range). They map
linearly onto the ADC's 0-4095: X left to right, Y top to bottom of the
screen (the ADC's Y runs the other way, as the panel's does). With the
settings partition's neutral calibration (`/psp/ts_settings` of
`0,4095,4095,-4095,0`), screen pixel (px, py) of the 320x240 screen is
value `px * 32767 / 319` on X and `py * 32767 / 239` on Y. The pen is
down while `left` is down; a move while down is a drag. A tap is a press,
about 100-200 ms, then `{"type": "btn", "data": {"button": "left",
"down": false}}`. The window's mouse and VNC send the same events.

**Top button.** The Chumby's top button (the squeeze switch, which the
guest reads from `/dev/switch`: one byte, 1 while pressed, 0 released) is
the machine's `button` property, a boolean:

    {"execute": "qom-set", "arguments": {"path": "/machine", "property": "button", "value": true}}
    {"execute": "qom-set", "arguments": {"path": "/machine", "property": "button", "value": false}}

`qom-get` reads it back. It drives keypad row 0 low while pressed, as the
hardware does, and the stock kernel polls it, so a press must last a
little while to be seen: `chumby-ctl ... button tap` holds it 300 ms.
A key holds it too, from any display's keyboard or from QMP's `send-key`
and `input-send-event`: F12, or the QKeyCode named by the machine's
`button-key` option (`-M chumby-classic,button-key=pause`; `none` for
no key). Other keys go on to the guest.

**Headphones.** The machine's `headphones` property, a boolean: true
plugs them in. The guest reads the jack's switch on keypad row 3
(`/proc/sys/sense1/hpin`); the stock software then mutes the speaker.

**Accelerometer.** The machine's `accel-x`, `accel-y` and `accel-z`
properties, integers in milli-g (-16000 to 16000), set at startup
(`-M chumby-classic,accel-x=0,...`) or with `qom-set` at any time. The
default, +1000 on Z and 0 on the others, is the Chumby standing still;
which way up the real sensor sits isn't known. They are the KXP74
accelerometer's (`/machine/accel`, whose `x-mg`, `y-mg` and `z-mg` are
the same values), read by the guest through `/dev/accel`.

**The board's outputs.** `query-chumby-state` returns the lines the guest
drives and the inputs above:

    {"execute": "query-chumby-state"}
    {"return": {"backlight": 65535, "lcd-on": true, "speaker-mute": false,
                "headphones": false, "button": false}}

`backlight` is the PWM's duty cycle, 0 to 65535, which also dims the
displayed screen (0 is black); `lcd-on` false blanks it. Changes come as
events: `CHUMBY_BACKLIGHT` `{"level"}` (at most one each 100 ms),
`CHUMBY_LCD` `{"on"}`, `CHUMBY_SPEAKER_MUTE` `{"muted"}` and
`CHUMBY_HEADPHONES` `{"inserted"}`. `chumby-ctl SOCKET events` prints
them as JSON lines.

**Sound.** `-audiodev DRIVER,id=ID -M chumby-classic,audiodev=ID`: the
TSC2100 codec plays to it as 16-bit stereo at the rate the guest
programs (44.1 kHz from the stock software), and records from it
(silence from a backend that can't record, such as CoreAudio). With
`-audiodev wav,id=a,path=out.wav` the sound goes to a file; QEMU leaves
the WAV header's sizes at zero when it exits, so read the samples after
the 44-byte header.

**USB.** QEMU's USB devices attach to the host controller's root hub with
`-device`: a stick (`-drive if=none,id=stick,file=stick.img,format=raw
-device usb-storage,drive=stick`), which the stock software mounts on
`/mnt/usb` from its first partition, `usb-kbd`, `usb-mouse`,
`usb-tablet`, `usb-audio`, `usb-hub`. Don't attach a network device to
anything that reaches the host's network unless you mean to.

**Identity.** The machine's `guid` (XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX),
`serial` (16 letters or digits) and `hwversion` (MAJOR.MINOR) properties
set what the crypto processor reports and the DC ID EEPROM holds; the
defaults are a made-up identity. Give each emulated Chumby its own GUID.

**Watchdog and reset.** The stock kernel arms the watchdog for 2.5 s and
services it every tick; a missed service performs QEMU's watchdog action
(`-action watchdog=reset`, the default; `none` while debugging), and
`reboot` in the guest resets the machine through it.
`/proc/resetReason` tells power-on, software, watchdog and external
(`system_reset`) resets apart.

**Saving and restoring.** `savevm NAME` (in the human monitor, or QMP's
`human-monitor-command`) saves the running machine into a qcow2 drive,
and `-loadvm NAME` (or `loadvm`) restores it in a fraction of a second.
Attach the NAND as a qcow2 overlay of your image for that:
`qemu-img create -f qcow2 -b nand.img -F raw nand.qcow2`, then
`-drive if=mtd,file=nand.qcow2,format=qcow2`. A state saved with
`-icount` loads only with it, and one saved without, only without.

**Screen.** QMP `screendump` with an absolute `filename` and `"format":
"png"` (8-bit RGB) or `"ppm"` (the default): the 320x240 frame as the
LCD controller composes it, background plane and graphic window. The
file is written by the QEMU process.

    {"execute": "screendump", "arguments": {"filename": "/abs/screen.png", "format": "png"}}

**Time.** By default the emulated clock follows the host's, as the real
device's does: animations, timers and sound run at their real pace, and
an idle Chumby costs the host little CPU (the vCPU sleeps in the
kernel's idle loop). Use this for a person at the screen. `-icount
shift=auto,sleep=off` lets the clock run ahead while the guest is idle,
which boots to the control panel in seconds and suits scripted tests;
sound then plays fast, and a host core stays busy.

## Legal

This is policy, not legal advice.

- qemu-chumby models the Chumby Classic's hardware so that unmodified
  software runs on it, for interoperability. It contains no Chumby
  software: no firmware, kernel, root disk, NAND dump or settings
  partition, no code from the stock software and no screenshots of its
  artwork.
- The firmware comes from your own device's flash backup and stays on
  your machine. It never goes in this repository, its releases, CI
  (artifacts or caches) or issue and pull request attachments.
- The emulated crypto processor has a fixed, made-up identity and refuses
  key and challenge requests. Keep it that way: the emulator must never
  impersonate a real device, or stand in for one to the Chumby service.
- Shipping anything from the stock software, ready-made images included,
  would need its rights holders' permission first: open an issue, not a
  pull request.

## Licence

QEMU is GPL-2.0-or-later, and so is everything here (the patches, each new
file with an SPDX `GPL-2.0-or-later` header, the scripts and the
documentation; see `COPYING`) except `chumby-image`, in `image/`, which is
MIT (`image/LICENSE`).
