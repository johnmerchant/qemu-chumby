#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
#
# install.sh [PREFIX]: builds chumby-desktop and installs it with its
# .desktop file and icon, so that it shows in KDE's and GNOME's app menus.
# PREFIX defaults to ~/.local (no root needed); /usr/local works too, as
# root. The checkout's QEMU (build/obj/qemu-system-arm, from ../../build),
# if built, goes in PREFIX/libexec/chumby-desktop, where the app looks
# first; otherwise it uses the qemu-system-arm on $PATH, or --qemu.
# Uninstall with: install.sh --uninstall [PREFIX]
set -eu

here=$(cd "$(dirname "$0")" && pwd)
id=io.github.johnmerchant.QemuChumby

uninstall=
if [ "${1:-}" = --uninstall ]; then
    uninstall=1
    shift
fi
prefix=${1:-$HOME/.local}

bin=$prefix/bin/chumby-desktop
desktop=$prefix/share/applications/$id.desktop
icon=$prefix/share/icons/hicolor/scalable/apps/$id.svg
libexec=$prefix/libexec/chumby-desktop
qemu=$here/../../build/obj/qemu-system-arm

if [ -n "$uninstall" ]; then
    rm -f "$bin" "$desktop" "$icon" "$libexec/qemu-system-arm"
    rmdir "$libexec" 2>/dev/null || true
    echo "removed chumby-desktop from $prefix"
else
    cargo build --release --locked --manifest-path "$here/Cargo.toml"
    target=${CARGO_TARGET_DIR:-$here/target}
    install -Dm755 "$target/release/chumby-desktop" "$bin"
    install -Dm644 "$here/data/$id.desktop" "$desktop"
    install -Dm644 "$here/data/chumby-desktop.svg" "$icon"
    if [ -x "$qemu" ]; then
        install -Dm755 "$qemu" "$libexec/qemu-system-arm"
        echo "installed $libexec/qemu-system-arm"
    fi
    echo "installed $bin"
    case ":$PATH:" in
        *":$prefix/bin:"*) ;;
        *) echo "note: $prefix/bin isn't on your PATH" ;;
    esac
fi

# Let the menus and the icon cache know, where the tools are installed.
command -v update-desktop-database >/dev/null 2>&1 &&
    update-desktop-database -q "$prefix/share/applications" 2>/dev/null || true
command -v gtk-update-icon-cache >/dev/null 2>&1 &&
    gtk-update-icon-cache -q -t "$prefix/share/icons/hicolor" 2>/dev/null || true
exit 0
