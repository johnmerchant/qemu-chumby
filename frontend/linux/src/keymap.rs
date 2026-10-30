// SPDX-License-Identifier: GPL-2.0-or-later
//! Keys to QEMU's QKeyCode names (qapi/ui.json), for input-send-event.
//!
//! On Linux desktops (X11 and Wayland alike) Qt reports the key's XKB
//! keycode, which is the evdev code plus 8: that names the physical key
//! whatever the layout, as QEMU's own GTK and SDL windows send it. Where
//! there is no such code (Qt's offscreen platform, other systems) the Qt
//! key is mapped as on a US keyboard.

/// Linux evdev codes 0 to 0xc2 to QKeyCode names, from QEMU's
/// ui/keycodemapdb (input-keymap-linux-to-qcode); "" for none.
const EVDEV: [&str; 0xc3] = [
    "", "esc", "1", "2", "3", "4", "5", "6",
    "7", "8", "9", "0", "minus", "equal", "backspace", "tab",
    "q", "w", "e", "r", "t", "y", "u", "i",
    "o", "p", "bracket_left", "bracket_right", "ret", "ctrl", "a", "s",
    "d", "f", "g", "h", "j", "k", "l", "semicolon",
    "apostrophe", "grave_accent", "shift", "backslash", "z", "x", "c", "v",
    "b", "n", "m", "comma", "dot", "slash", "shift_r", "kp_multiply",
    "alt", "spc", "caps_lock", "f1", "f2", "f3", "f4", "f5",
    "f6", "f7", "f8", "f9", "f10", "num_lock", "scroll_lock", "kp_7",
    "kp_8", "kp_9", "kp_subtract", "kp_4", "kp_5", "kp_6", "kp_add", "kp_1",
    "kp_2", "kp_3", "kp_0", "kp_decimal", "", "", "less", "f11",
    "f12", "ro", "", "hiragana", "henkan", "katakanahiragana", "muhenkan", "",
    "kp_enter", "ctrl_r", "kp_divide", "sysrq", "alt_r", "lf", "home", "up",
    "pgup", "left", "right", "end", "down", "pgdn", "insert", "delete",
    "", "audiomute", "volumedown", "volumeup", "power", "kp_equals", "", "pause",
    "", "kp_comma", "lang1", "lang2", "yen", "meta_l", "meta_r", "compose",
    "stop", "again", "props", "undo", "front", "copy", "open", "paste",
    "find", "cut", "help", "menu", "calculator", "", "sleep", "wake",
    "", "", "", "", "", "", "", "",
    "", "", "", "mail", "ac_bookmarks", "computer", "ac_back", "ac_forward",
    "", "", "", "audionext", "audioplay", "audioprev", "audiostop", "",
    "", "", "", "", "ac_home", "ac_refresh", "", "",
    "", "", "", "", "", "", "", "f13",
    "f14", "f15", "f16", "f17", "f18", "f19", "f20", "f21",
    "f22", "f23", "f24",
];

const KEYPAD_MODIFIER: i32 = 0x2000_0000;

/// The QKeyCode for a key event: from the native scan code where the
/// platform gives XKB keycodes (`xcb`, `wayland`), else from the Qt key.
pub fn qcode(platform: &str, native_scan_code: u32, qt_key: i32, modifiers: i32) -> Option<&'static str> {
    let xkb = matches!(platform, "xcb" | "wayland" | "wayland-egl" | "eglfs" | "linuxfb");
    if xkb && native_scan_code >= 8 {
        let evdev = (native_scan_code - 8) as usize;
        if let Some(q) = EVDEV.get(evdev).filter(|q| !q.is_empty()) {
            return Some(q);
        }
    }
    from_qt_key(qt_key, modifiers & KEYPAD_MODIFIER != 0)
}

fn from_qt_key(key: i32, keypad: bool) -> Option<&'static str> {
    if keypad {
        let kp = match key {
            0x30 => "kp_0", 0x31 => "kp_1", 0x32 => "kp_2", 0x33 => "kp_3", 0x34 => "kp_4",
            0x35 => "kp_5", 0x36 => "kp_6", 0x37 => "kp_7", 0x38 => "kp_8", 0x39 => "kp_9",
            0x2a => "kp_multiply", 0x2b => "kp_add", 0x2d => "kp_subtract",
            0x2e => "kp_decimal", 0x2f => "kp_divide", 0x3d => "kp_equals",
            0x0100_0004 | 0x0100_0005 => "kp_enter",
            _ => "",
        };
        if !kp.is_empty() {
            return Some(kp);
        }
    }
    const LETTERS: [&str; 26] = [
        "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "p", "q",
        "r", "s", "t", "u", "v", "w", "x", "y", "z",
    ];
    const DIGITS: [&str; 10] = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"];
    const FKEYS: [&str; 24] = [
        "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10", "f11", "f12", "f13", "f14",
        "f15", "f16", "f17", "f18", "f19", "f20", "f21", "f22", "f23", "f24",
    ];
    Some(match key {
        0x41..=0x5a => LETTERS[(key - 0x41) as usize],
        0x30..=0x39 => DIGITS[(key - 0x30) as usize],
        0x0100_0030..=0x0100_0047 => FKEYS[(key - 0x0100_0030) as usize],
        0x20 => "spc",
        // The symbols, and their shifted forms, as on a US keyboard: the
        // Shift key itself goes to the guest too.
        0x2d | 0x5f => "minus",
        0x3d | 0x2b => "equal",
        0x5b | 0x7b => "bracket_left",
        0x5d | 0x7d => "bracket_right",
        0x5c | 0x7c => "backslash",
        0x3b | 0x3a => "semicolon",
        0x27 | 0x22 => "apostrophe",
        0x60 | 0x7e => "grave_accent",
        0x2c | 0x3c => "comma",
        0x2e | 0x3e => "dot",
        0x2f | 0x3f => "slash",
        0x21 => "1",
        0x40 => "2",
        0x23 => "3",
        0x24 => "4",
        0x25 => "5",
        0x5e => "6",
        0x26 => "7",
        0x2a => "8",
        0x28 => "9",
        0x29 => "0",
        0x0100_0000 => "esc",
        0x0100_0001 | 0x0100_0002 => "tab",
        0x0100_0003 => "backspace",
        0x0100_0004 => "ret",
        0x0100_0005 => "kp_enter",
        0x0100_0006 => "insert",
        0x0100_0007 => "delete",
        0x0100_0008 => "pause",
        0x0100_0009 => "print",
        0x0100_000a => "sysrq",
        0x0100_0010 => "home",
        0x0100_0011 => "end",
        0x0100_0012 => "left",
        0x0100_0013 => "up",
        0x0100_0014 => "right",
        0x0100_0015 => "down",
        0x0100_0016 => "pgup",
        0x0100_0017 => "pgdn",
        0x0100_0020 => "shift",
        0x0100_0021 => "ctrl",
        0x0100_0022 => "meta_l",
        0x0100_0023 => "alt",
        0x0100_1103 => "alt_r",
        0x0100_0024 => "caps_lock",
        0x0100_0025 => "num_lock",
        0x0100_0026 => "scroll_lock",
        0x0100_0055 => "menu",
        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    use super::qcode;

    #[test]
    fn scan_codes_and_keys() {
        // XKB keycode 38 is evdev 30, the A key, whatever the layout says.
        assert_eq!(qcode("wayland", 38, 0x51, 0), Some("a"));
        assert_eq!(qcode("xcb", 62, 0x0100_0020, 0), Some("shift_r"));
        assert_eq!(qcode("offscreen", 0, 0x41, 0), Some("a"));
        assert_eq!(qcode("offscreen", 0, 0x21, 0), Some("1"));
        assert_eq!(qcode("offscreen", 0, 0x31, 0x2000_0000), Some("kp_1"));
        assert_eq!(qcode("offscreen", 0, 0x0100_003b, 0), Some("f12"));
        assert_eq!(qcode("offscreen", 0, 0x0100_ffff, 0), None);
    }
}
