# qemu-chumby

[![CI](https://github.com/johnmerchant/qemu-chumby/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/johnmerchant/qemu-chumby/actions/workflows/ci.yml?query=branch%3Amain)
[![Licence: GPL-2.0-or-later](https://img.shields.io/badge/licence-GPL--2.0--or--later-blue)](#licence)
[![QEMU 11.1.3](https://img.shields.io/badge/QEMU-11.1.3-orange)](qemu-release)
[![Platforms: macOS, Linux](https://img.shields.io/badge/platforms-macOS%20%7C%20Linux-lightgrey)](#prebuilt-binaries)
[![Prebuilt binaries](https://img.shields.io/badge/prebuilt-binaries-brightgreen)](https://github.com/johnmerchant/qemu-chumby/releases/tag/prebuilt)
[![Website](https://img.shields.io/badge/website-qemu--chumby-teal)](https://johnmerchant.github.io/qemu-chumby/)

A QEMU machine for the Chumby Classic, `qemu-system-arm -M chumby-classic`:
its Freescale i.MX21 (ARM926EJ-S) and the board's devices, enough to run
the device's own Linux 2.6.16 and control panel unmodified.

## Quick start

Download the newest build for your platform from the
[site](https://johnmerchant.github.io/qemu-chumby/), or build it:

    ./build                  # build/obj/qemu-system-arm; lists what's missing
    nix build github:johnmerchant/qemu-chumby     # or with Nix, in result/bin

Then boot your Chumby's kernel and NAND image (see [Images](#images)):

    qemu-system-arm -M chumby-classic -kernel zImage \
        -drive if=mtd,file=nand.img,format=raw,snapshot=on \
        -nic none -serial stdio -qmp unix:qmp.sock,server=on,wait=off

### Prebuilt binaries

CI publishes each commit on main's builds on the
[`prebuilt`](https://github.com/johnmerchant/qemu-chumby/releases/tag/prebuilt)
release, each with its `.sha256` (ARCH is `x86_64` or `aarch64`):

| Download | For | Install |
| --- | --- | --- |
| `qemu-chumby-COMMIT-PLATFORM.tar.xz` | Headless QEMU that needs nothing installed (below) | Unpack; run `qemu-system-arm` |
| `qemu-chumby-COMMIT-ARCH.flatpak` | Flatpak (desktop app with sound): chumby-desktop with its QEMU, sandboxed, no network | `flatpak install --user ./qemu-chumby-*.flatpak`, then `flatpak run io.github.johnmerchant.QemuChumby` |
| `qemu-chumby-COMMIT-DISTRO-VERSION-ARCH.deb` or `.rpm` | QEMU with a window and sound on the distro's own libraries, as `qemu-chumby-system-arm` beside the distro's QEMU, with `chumby-machine` and `chumby-ctl`; for Debian 13, Ubuntu 26.04 and 26.10, Fedora 44 and 43 | `sudo apt install ./qemu-chumby-*.deb` or `sudo dnf install ./qemu-chumby-*.rpm` |

The packages' version is QEMU's plus the commit's date and ID
(`11.1.2+chumby.20261030131130.g3673860`), so each commit upgrades the
one before; their dependencies are what the binary links
(`dpkg-shlibdeps`, RPM's `elfdeps`). `packaging/build-package` and
`flatpak/build` build them.

The tarballs need nothing installed: unpack and run. Each tarball's
`RUNTIME` says what it was built from and what it links.

| Platform | What it is |
| --- | --- |
| `linux-x86_64`, `linux-aarch64` | Static; headless (VNC, no window or sound) |
| `macos-arm64` | macOS 15 or later, with the window and sound. Signed ad hoc: if a browser downloaded it, `xattr -dr com.apple.quarantine` what it unpacked |

## What it emulates

The i.MX21's interrupt controller, timers, UARTs, clocks, GPIO, keypad
port, SPI, LCD, NAND flash, PWM, DMA, audio, USB host, watchdog, RTC and
I2C, and the board's touchscreen and codec, sensor card and crypto
processor. Each device, its options and its limits are on the machine's
docs page, `docs/system/arm/chumby-classic.rst`, which
[`patches/`](patches) adds. Its "Frontend interface" section is the
reference for the stable control surface: the machine properties,
`query-chumby-state`, the `CHUMBY_*` events, the pen and key conventions
and `screendump`.

The patches apply to QEMU 11.1.3 (`qemu-release` pins the tarball and its
SHA-256). CI's daily `qemu-sync` job (`./qemu-sync`) proposes each newer
release as a pull request, with the series re-exported for it by
`./dev-series` (or, if a patch no longer applies, the pull request says
which), and whose CI says whether they still apply and build.

### Modelled from real hardware

Some bugs in kernels passed here and failed on a real Chumby, so the
machine now holds a guest to more of what the hardware needs (`0028` to
`0034`). Register values come from a running stock Chumby (hardware 3.8),
the rest from Chumby's published kernel source and TI's TSC2100 data sheet.
The i.MX21 reference manual was not consulted, so what is marked inferred
below has not been checked against it.

| What | Evidence |
| --- | --- |
| The clock module starts with a real Chumby's values | Read from a running Chumby |
| The oscillator is 16 MHz, so MPLL 350 MHz, SPLL 288 MHz, PERCLK1 15.9 MHz; GPTs and PWM count at that PERCLK1, and a kernel assuming 26 MHz keeps time 1.6 times slow | Inferred from SPCTL0 and USB_DIV having to make USB's 48 MHz and the stock audio driver's 16 MHz; a device's timing agrees |
| TSC2100 PINTDAV modes, with the pin latched low in modes 10 and 11 | The data sheet, Table 2 |
| PINTDAV goes low again while the pen stays down, after 100 µs | Inferred from the stock driver; the delay is a stand-in |
| USB does nothing with its clocks off | The stock board file enables them; the effect is inferred |
| USB devices answer only with a 48 MHz clock, the root port's pins multiplexed to it, and on port 2 PB25-PB29 outputs and USBCTRL's HOST1_TXEN_OE set | What the stock board file and driver do, and read values; that hardware requires each is inferred. Without them transfers end "device not responding" (-110 in Linux), as a real Chumby's did |
| USBCTRL resets to 0x000f1000; HWMODE's top half and ROOTHUBA as read | Read values; that USBCTRL's is a reset value is inferred |
| `handoff=on`: LCD window on and opaque, ports B, D and E and LCD registers as read, noise in RAM | Read values; the window's address is a stand-in |

This changes the machine in ways a user will see:

- The board's USB hub is on root hub port 2 by default (`internal-hub=off`
  removes it), and devices given no port, `chumby-machine --stick` included,
  attach behind it. A kernel that can't drive port 2 loses them too.
- A kernel with the wrong oscillator in its clock tree now keeps the wrong
  time here.
- Saved states from before this won't load.

Not modelled: what USBCTRL's other bits, SKPRTRY and the transceiver modes
do to a transfer, for lack of a source; settle times, caches, and DMA left
running by a previous kernel. A failure seen on a device, a jump from stock
that froze the screen until the watchdog reset it, doesn't reproduce here.
`tests/watchdog/run` checks that a hung kernel is reset every 64 s.

Each patch is a DEP-3 header (`Description:`, `Author:`, then
`Upstream-Status: Inappropriate [AI generated code]`, `Signed-off-by:`
and `Claude-Session:`), a line `---` and the diff; new patches carry the
same header. `./dev-series import DIR` makes a QEMU 11.1.2 tree a git
tree with one commit per patch, and `./dev-series export DIR` writes
them back, byte for byte (CI checks the round trip).

## Images

The stock firmware boots from two files from your own Chumby's flash
backup: its kernel (`zImage`) and a NAND image of the whole chip
(`nand.img`). `chumby-image`, in `image/`, makes the NAND image from a
backup: `cargo run --manifest-path image/Cargo.toml -- --help`. Other
kernels boot too, with `-initrd` and `-append`.

## Tools

Each prints its options with `--help`. The scripts (`build`,
`tests/smoke/run`, `tests/linux/run`, `frontend/mac/build-app`,
`frontend/linux/install.sh`) describe themselves in their header comments.

- `chumby-emu`: the Chumby as a desktop app, with a window, sound and a
  control panel; it runs the native app below once that is built.
  `./chumby-emu IMAGES`, or `nix run github:johnmerchant/qemu-chumby#emu -- IMAGES`.
- Chumby.app, the native macOS app: `frontend/mac/build-app`, then
  `open frontend/mac/build/Chumby.app`.
- chumby-desktop, the native Linux app: `frontend/linux/install.sh`.
- `chumby-machine`: runs the machine headless and drives it, for scripts
  and tests, as a command line and a Python module (`chumby_machine.py`,
  whose header describes the control surface a harness relies on).
  `./chumby-machine --dir m start --kernel zImage`.
- `--link SOCK` (each of the above): UART2 to a unix socket that a
  program on the host listens on, a byte stream to it and no network.
- `chumby-ctl`: drives a running machine over its QMP socket.
  `./chumby-ctl qmp.sock tap 160 120`.

## Legal

qemu-chumby is an independent project, not affiliated with or endorsed by
Chumby Industries, Blue Octy or anyone holding rights in Chumby; "Chumby"
is a trademark of its owner, used only to say what hardware this models.
The project's policy (not legal advice):

- No Chumby software: firmware images (kernel, root disk, NAND dump,
  settings) never go in this repository, CI, releases or issue and pull
  request attachments. Yours stays on your machine.
- No screenshots of the stock software.
- The emulated crypto processor keeps a made-up identity and refuses key
  and challenge requests: it never impersonates a real device.
- Shipping anything from the stock software needs its rights holders'
  permission first: open an issue, not a pull request.

## Licence

GPL-2.0-or-later, as QEMU (`COPYING`), except `chumby-image` in `image/`,
which is MIT (`image/LICENSE`).
