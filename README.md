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
