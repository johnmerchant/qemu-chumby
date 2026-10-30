// SPDX-License-Identifier: GPL-2.0-or-later
//
// macOS virtual key codes (kVK_*, Carbon's Events.h) to QEMU's QKeyCode
// names, for QMP input-send-event: the table QEMU's own Cocoa display
// uses, from keycodemapdb's keymaps.csv ("OS-X Keycode" to "QEMU
// QKeyCode").

public enum KeyMap {
    public static let qcodes: [UInt16: String] = [
        0x00: "a", // ANSI_A
        0x01: "s", // ANSI_S
        0x02: "d", // ANSI_D
        0x03: "f", // ANSI_F
        0x04: "h", // ANSI_H
        0x05: "g", // ANSI_G
        0x06: "z", // ANSI_Z
        0x07: "x", // ANSI_X
        0x08: "c", // ANSI_C
        0x09: "v", // ANSI_V
        0x0A: "less", // ISO_Section
        0x0B: "b", // ANSI_B
        0x0C: "q", // ANSI_Q
        0x0D: "w", // ANSI_W
        0x0E: "e", // ANSI_E
        0x0F: "r", // ANSI_R
        0x10: "y", // ANSI_Y
        0x11: "t", // ANSI_T
        0x12: "1", // ANSI_1
        0x13: "2", // ANSI_2
        0x14: "3", // ANSI_3
        0x15: "4", // ANSI_4
        0x16: "6", // ANSI_6
        0x17: "5", // ANSI_5
        0x18: "equal", // ANSI_Equal
        0x19: "9", // ANSI_9
        0x1A: "7", // ANSI_7
        0x1B: "minus", // ANSI_Minus
        0x1C: "8", // ANSI_8
        0x1D: "0", // ANSI_0
        0x1E: "bracket_right", // ANSI_RightBracket
        0x1F: "o", // ANSI_O
        0x20: "u", // ANSI_U
        0x21: "bracket_left", // ANSI_LeftBracket
        0x22: "i", // ANSI_I
        0x23: "p", // ANSI_P
        0x24: "ret", // Return
        0x25: "l", // ANSI_L
        0x26: "j", // ANSI_J
        0x27: "apostrophe", // ANSI_Quote
        0x28: "k", // ANSI_K
        0x29: "semicolon", // ANSI_Semicolon
        0x2A: "backslash", // ANSI_Backslash
        0x2B: "comma", // ANSI_Comma
        0x2C: "slash", // ANSI_Slash
        0x2D: "n", // ANSI_N
        0x2E: "m", // ANSI_M
        0x2F: "dot", // ANSI_Period
        0x30: "tab", // Tab
        0x31: "spc", // Space
        0x32: "grave_accent", // ANSI_Grave
        0x33: "backspace", // Delete
        0x35: "esc", // Escape
        0x36: "meta_r", // RightCommand
        0x37: "meta_l", // Command
        0x38: "shift", // Shift
        0x39: "caps_lock", // CapsLock
        0x3A: "alt", // Option
        0x3B: "ctrl", // Control
        0x3C: "shift_r", // RightShift
        0x3D: "alt_r", // RightOption
        0x3E: "ctrl_r", // RightControl
        0x40: "f17", // F17
        0x41: "kp_decimal", // ANSI_KeypadDecimal
        0x43: "kp_multiply", // ANSI_KeypadMultiply
        0x45: "kp_add", // ANSI_KeypadPlus
        0x47: "num_lock", // ANSI_KeypadClear
        0x48: "volumeup", // VolumeUp
        0x49: "volumedown", // VolumeDown
        0x4A: "audiomute", // Mute
        0x4B: "kp_divide", // ANSI_KeypadDivide
        0x4C: "kp_enter", // ANSI_KeypadEnter
        0x4E: "kp_subtract", // ANSI_KeypadMinus
        0x4F: "f18", // F18
        0x50: "f19", // F19
        0x51: "kp_equals", // ANSI_KeypadEquals
        0x52: "kp_0", // ANSI_Keypad0
        0x53: "kp_1", // ANSI_Keypad1
        0x54: "kp_2", // ANSI_Keypad2
        0x55: "kp_3", // ANSI_Keypad3
        0x56: "kp_4", // ANSI_Keypad4
        0x57: "kp_5", // ANSI_Keypad5
        0x58: "kp_6", // ANSI_Keypad6
        0x59: "kp_7", // ANSI_Keypad7
        0x5A: "f20", // F20
        0x5B: "kp_8", // ANSI_Keypad8
        0x5C: "kp_9", // ANSI_Keypad9
        0x5D: "yen", // JIS_Yen
        0x5E: "ro", // JIS_Underscore
        0x60: "f5", // F5
        0x61: "f6", // F6
        0x62: "f7", // F7
        0x63: "f3", // F3
        0x64: "f8", // F8
        0x65: "f9", // F9
        0x66: "lang2", // JIS_Eisu
        0x67: "f11", // F11
        0x68: "lang1", // JIS_Kana
        0x69: "f13", // F13
        0x6A: "f16", // F16
        0x6B: "f14", // F14
        0x6D: "f10", // F10
        0x6E: "compose", // the PC keyboard's Menu key
        0x6F: "f12", // F12
        0x71: "f15", // F15
        0x72: "insert", // Help, where a PC keyboard has Insert
        0x73: "home", // Home
        0x74: "pgup", // PageUp
        0x75: "delete", // ForwardDelete
        0x76: "f4", // F4
        0x77: "end", // End
        0x78: "f2", // F2
        0x79: "pgdn", // PageDown
        0x7A: "f1", // F1
        0x7B: "left", // LeftArrow
        0x7C: "right", // RightArrow
        0x7D: "down", // DownArrow
        0x7E: "up", // UpArrow
    ]

    public static func qcode(forKeyCode code: UInt16) -> String? { qcodes[code] }

    // The modifier keys, which macOS reports with flagsChanged, not
    // keyDown and keyUp. Caps Lock reports its lock state instead.
    public static let shift: UInt16 = 0x38, rightShift: UInt16 = 0x3C
    public static let control: UInt16 = 0x3B, rightControl: UInt16 = 0x3E
    public static let option: UInt16 = 0x3A, rightOption: UInt16 = 0x3D
    public static let command: UInt16 = 0x37, rightCommand: UInt16 = 0x36
    public static let capsLock: UInt16 = 0x39
    public static let function: UInt16 = 0x3F
    public static let f12: UInt16 = 0x6F

    public static let modifiers: Set<UInt16> = [
        shift, rightShift, control, rightControl, option, rightOption,
        command, rightCommand, capsLock, function,
    ]
}
