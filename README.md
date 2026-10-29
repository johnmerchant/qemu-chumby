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
it.

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
| Crypto processor on UART3 | Hardware version 3.8 with a made-up identity: GUID `C40BB1E0-0000-4000-8000-0E4000000001`, serial number `0000000000000000`. It holds no keys and refuses key and challenge requests |
| Clocks (CRM) and system control | Registers, PLLs locked at the boot loader's settings |
| GPIO ports A-F | Complete for the drivers |
| Keypad port | Used as GPIO: the data register reads the pins. The top button (`/dev/switch`) is row 0; no scan interrupts |
| CSPI1-3 | Complete except DMA |
| TSC2100 touchscreen on CSPI3 | Touch conversions and PINTDAV (GPIO PE19); the pen is QEMU's absolute pointer. Audio registers only, no sound |
| LCD controller | Background plane and graphic window (alpha, colour key), 16 bpp, as a QEMU display |
| NAND flash controller | 64 MiB small-page chip; reads, programs and erases, written back to the image |
| PWM | Registers |
| USB host | Control registers and an empty three-port root hub; no transfers |
| DMA, SSI audio, watchdog, RTC, SDHC, I2C | Not modelled: registers read back as written |

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

## Building

The patches apply to QEMU 11.1.2 (`qemu-release` pins the tarball and its
SHA-256).

With Nix, the flake's package is `qemu-system-arm` with the machine
(plus `chumby-ctl`) for `aarch64-darwin` (Apple silicon), `x86_64-darwin`,
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

## Images

The machine needs two files from your own Chumby's flash backup:

- The kernel: the zImage at the start of the Kernel1 partition.
- A NAND image of the whole 64 MiB chip in `nanddump`'s layout: 131072
  records of 528 bytes, each a page's 512 data bytes followed by its 16
  spare (OOB) bytes, 69206016 bytes in all.

Programs and erases are written back to the NAND image, as the Chumby
writes its flash. Keep a copy, or use `snapshot=on` or `readonly=on` on
the drive to leave the image unchanged.

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
- the console, with a line to type shell commands into

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

### Testing on Linux

`tests/linux/run IMAGES` builds the machine on Debian 13 in a container
(Apple's `container`, Docker or Podman, on a Mac or on Linux) and checks
a KDE Plasma 6 desktop there, with KWin on X11 and as a Wayland
compositor: QEMU's GTK and SDL windows come up under KWin and show the
Chumby's screen, sound reaches PulseAudio, and chumby-emu's Qt panel
drives the machine. The checks run with no network.

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

What a harness driving the machine (a test runner, `dev/emulate` in
neochumby) relies on. All of it is standard QEMU; nothing here is
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

**Screen.** QMP `screendump` with an absolute `filename` and `"format":
"png"` (8-bit RGB) or `"ppm"` (the default): the 320x240 frame as the
LCD controller composes it, background plane and graphic window. The
file is written by the QEMU process.

    {"execute": "screendump", "arguments": {"filename": "/abs/screen.png", "format": "png"}}

**Time.** By default the emulated clock follows the host's.
`-icount shift=auto,sleep=off` lets it run ahead while the guest is idle.

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

QEMU is GPL-2.0-or-later, and so is everything here: the patches (each
new file carries an SPDX `GPL-2.0-or-later` header), the scripts and the
documentation. See `COPYING`.
