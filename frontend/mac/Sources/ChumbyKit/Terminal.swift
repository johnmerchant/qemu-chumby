// SPDX-License-Identifier: GPL-2.0-or-later
//
// The console's screen: enough of a VT100 for a shell on a serial port
// (BusyBox's line editing, ls's colours, clear): text, CR, LF, BS, TAB,
// cursor movement and positioning, erasing, and colours. Other sequences
// are read and dropped. The screen is the last `rows` lines of a
// scrollback, so what scrolls off stays readable above it.

import Foundation

public struct TermAttr: Equatable, Sendable {
    /// ANSI colour 0-15, or nil for the default.
    public var fg: UInt8? = nil
    public var bg: UInt8? = nil
    public var bold = false
    public var inverse = false
    public var underline = false
    public init() {}
}

public struct TermCell: Equatable, Sendable {
    public var ch: Character
    public var attr: TermAttr
    public init(ch: Character, attr: TermAttr) {
        self.ch = ch
        self.attr = attr
    }
}

public final class Terminal {
    public let cols: Int
    public let rows: Int
    public let maxLines: Int
    public private(set) var lines: [[TermCell]] = [[]]
    /// The cursor: a line of `lines`, and a column.
    public private(set) var cursorLine = 0
    public private(set) var cursorCol = 0
    private var attr = TermAttr()
    private var utf8: [UInt8] = []
    private var utf8Need = 0

    private enum State { case ground, esc, csi, osc, oscEsc, charset }
    private var state = State.ground
    private var params = ""
    /// Wrap before the next character (the cursor sits past the last column).
    private var pendingWrap = false

    public init(cols: Int = 80, rows: Int = 24, maxLines: Int = 5000) {
        self.cols = cols
        self.rows = rows
        self.maxLines = maxLines
    }

    /// The first line of the screen.
    public var screenTop: Int { max(0, lines.count - rows) }

    public func text(line i: Int) -> String {
        String(lines[i].map(\.ch))
    }

    /// All of it as plain text, trailing blanks dropped.
    public var plainText: String {
        lines.map { l in
            var s = String(l.map(\.ch))
            while s.last == " " { s.removeLast() }
            return s
        }.joined(separator: "\n")
    }

    public func feed(_ data: [UInt8]) {
        // Everything a feed changes is on the screen or below it.
        changedFrom = min(changedFrom, screenTop, cursorLine)
        for b in data { byte(b) }
    }

    private var changedFrom = 0
    private var droppedLines = 0

    /// What changed since the last call, for a view that redraws only
    /// that: how many lines left the top of the scrollback, and the first
    /// line (counted after those left) that may differ.
    public func takeChanges() -> (dropped: Int, from: Int) {
        let r = (droppedLines, min(changedFrom, lines.count))
        droppedLines = 0
        changedFrom = lines.count
        return r
    }

    public func feed(_ s: String) { feed(Array(s.utf8)) }

    private func byte(_ b: UInt8) {
        if utf8Need > 0 {
            if b & 0xC0 == 0x80 {
                utf8.append(b)
                utf8Need -= 1
                if utf8Need == 0 {
                    let s = String(decoding: utf8, as: UTF8.self)
                    utf8 = []
                    for c in s { put(c) }
                }
                return
            }
            utf8 = []
            utf8Need = 0
            put("\u{FFFD}")
        }
        switch state {
        case .ground: ground(b)
        case .esc:
            switch b {
            case UInt8(ascii: "["): state = .csi; params = ""
            case UInt8(ascii: "]"): state = .osc
            case UInt8(ascii: "("), UInt8(ascii: ")"): state = .charset
            case UInt8(ascii: "c"): reset(); state = .ground
            case UInt8(ascii: "D"): lineFeed(); state = .ground
            case UInt8(ascii: "E"): cursorCol = 0; lineFeed(); state = .ground
            case UInt8(ascii: "M"): reverseIndex(); state = .ground
            default: state = .ground
            }
        case .charset: state = .ground
        case .osc:
            if b == 7 { state = .ground } else if b == 0x1B { state = .oscEsc }
        case .oscEsc: state = b == UInt8(ascii: "\\") ? .ground : .osc
        case .csi:
            if (0x30...0x3F).contains(b) {
                params.append(Character(UnicodeScalar(b)))
            } else if (0x20...0x2F).contains(b) {
                // intermediate bytes: none we act on
            } else {
                csi(Character(UnicodeScalar(b)))
                state = .ground
            }
        }
    }

    private func ground(_ b: UInt8) {
        switch b {
        case 0x1B: state = .esc
        case 13: cursorCol = 0; pendingWrap = false
        case 10, 11, 12: lineFeed()
        case 8:
            if pendingWrap { pendingWrap = false } else if cursorCol > 0 { cursorCol -= 1 }
        case 9:
            cursorCol = min(cols - 1, (cursorCol / 8 + 1) * 8)
        case 7, 0, 14, 15: break
        case 0x20...0x7E: put(Character(UnicodeScalar(b)))
        case 0xC0...0xDF: utf8 = [b]; utf8Need = 1
        case 0xE0...0xEF: utf8 = [b]; utf8Need = 2
        case 0xF0...0xF7: utf8 = [b]; utf8Need = 3
        case 0x7F: break
        default:
            if b >= 0x80 { put("\u{FFFD}") }
        }
    }

    private func put(_ c: Character) {
        if pendingWrap {
            pendingWrap = false
            cursorCol = 0
            lineFeed()
        }
        pad(cursorLine, to: cursorCol + 1)
        lines[cursorLine][cursorCol] = TermCell(ch: c, attr: attr)
        if cursorCol == cols - 1 {
            pendingWrap = true
        } else {
            cursorCol += 1
        }
    }

    private func pad(_ line: Int, to n: Int) {
        if lines[line].count < n {
            lines[line] += Array(repeating: TermCell(ch: " ", attr: TermAttr()),
                                 count: n - lines[line].count)
        }
    }

    private func lineFeed() {
        pendingWrap = false
        cursorLine += 1
        if cursorLine == lines.count {
            lines.append([])
            trim()
        }
    }

    private func reverseIndex() {
        if cursorLine > screenTop {
            cursorLine -= 1
        } else {
            lines.insert([], at: cursorLine)
            if lines.count > screenTop + rows { lines.removeLast() }
        }
    }

    private func trim() {
        let extra = lines.count - maxLines
        if extra > 0 {
            lines.removeFirst(extra)
            cursorLine -= extra
            droppedLines += extra
            changedFrom = max(0, changedFrom - extra)
        }
    }

    private func reset() {
        attr = TermAttr()
        clearScreen()
    }

    /// Scrolls what the screen holds into the scrollback and starts a
    /// blank one, with the cursor at its top.
    private func clearScreen() {
        while lines.count > 1, lines.last!.allSatisfy({ $0.ch == " " }) { lines.removeLast() }
        changedFrom = min(changedFrom, lines.count)
        lines += Array(repeating: [], count: rows)
        trim()
        cursorLine = screenTop
        cursorCol = 0
    }

    private func csi(_ final: Character) {
        let priv = params.hasPrefix("?")
        let ps = params.drop(while: { $0 == "?" || $0 == ">" })
            .split(separator: ";", omittingEmptySubsequences: false)
            .map { Int($0) }
        func p(_ i: Int, _ d: Int) -> Int {
            i < ps.count ? (ps[i] ?? d) : d
        }
        let n = max(1, p(0, 1))
        pendingWrap = false
        if priv { return } // modes: cursor visibility, wrap... ignored
        switch final {
        case "A": cursorLine = max(screenTop, cursorLine - n)
        case "B", "e":
            cursorLine = min(screenTop + rows - 1, cursorLine + n)
            ensureLine(cursorLine)
        case "C", "a": cursorCol = min(cols - 1, cursorCol + n)
        case "D": cursorCol = max(0, cursorCol - n)
        case "G", "`": cursorCol = min(cols - 1, n - 1)
        case "d":
            cursorLine = screenTop + min(rows - 1, n - 1)
            ensureLine(cursorLine)
        case "H", "f":
            let r = min(rows, max(1, p(0, 1))), c = min(cols, max(1, p(1, 1)))
            // Address the screen as rows lines, even before that many exist.
            while lines.count < rows { lines.append([]) }
            cursorLine = screenTop + r - 1
            cursorCol = c - 1
        case "J":
            switch p(0, 0) {
            case 0:
                eraseLine(cursorLine, from: cursorCol)
                for l in (cursorLine + 1)..<lines.count { lines[l] = [] }
            case 1:
                for l in screenTop..<max(screenTop, cursorLine) { lines[l] = [] }
                eraseLine(cursorLine, to: cursorCol)
            default:
                let col = cursorCol, row = cursorLine - screenTop
                clearScreen()
                cursorLine = screenTop + max(0, row)
                cursorCol = col
            }
        case "K":
            switch p(0, 0) {
            case 0: eraseLine(cursorLine, from: cursorCol)
            case 1: eraseLine(cursorLine, to: cursorCol)
            default: lines[cursorLine] = []
            }
        case "P":
            let l = cursorLine
            if cursorCol < lines[l].count {
                lines[l].removeSubrange(cursorCol..<min(lines[l].count, cursorCol + n))
            }
        case "@":
            let l = cursorLine
            if cursorCol < lines[l].count {
                lines[l].insert(contentsOf: Array(repeating: TermCell(ch: " ", attr: TermAttr()), count: n),
                                at: cursorCol)
                if lines[l].count > cols { lines[l].removeLast(lines[l].count - cols) }
            }
        case "X":
            pad(cursorLine, to: cursorCol + n)
            for i in cursorCol..<(cursorCol + n) { lines[cursorLine][i] = TermCell(ch: " ", attr: TermAttr()) }
        case "L":
            for _ in 0..<n { lines.insert([], at: cursorLine) }
            let end = screenTop + rows
            if lines.count > end { lines.removeSubrange(end..<min(lines.count, end + n)) }
        case "M":
            for _ in 0..<n where cursorLine < lines.count - 1 { lines.remove(at: cursorLine) }
            ensureLine(screenTop + rows - 1)
        case "m": sgr(ps.isEmpty ? [0] : ps.map { $0 ?? 0 })
        default: break // n (reports), r (scroll region), h/l, s/u: ignored
        }
    }

    private func ensureLine(_ l: Int) {
        while lines.count <= l { lines.append([]) }
        trim()
    }

    private func eraseLine(_ l: Int, from c: Int) {
        if c < lines[l].count { lines[l].removeSubrange(c...) }
    }

    private func eraseLine(_ l: Int, to c: Int) {
        pad(l, to: c + 1)
        for i in 0...c { lines[l][i] = TermCell(ch: " ", attr: TermAttr()) }
    }

    private func sgr(_ codes: [Int]) {
        var i = 0
        while i < codes.count {
            let c = codes[i]
            switch c {
            case 0: attr = TermAttr()
            case 1: attr.bold = true
            case 4: attr.underline = true
            case 7: attr.inverse = true
            case 22: attr.bold = false
            case 24: attr.underline = false
            case 27: attr.inverse = false
            case 30...37: attr.fg = UInt8(c - 30)
            case 39: attr.fg = nil
            case 40...47: attr.bg = UInt8(c - 40)
            case 49: attr.bg = nil
            case 90...97: attr.fg = UInt8(c - 90 + 8)
            case 100...107: attr.bg = UInt8(c - 100 + 8)
            case 38, 48:
                // 256-colour and RGB: take the nearest of the 16 (roughly).
                if i + 2 < codes.count && codes[i + 1] == 5 {
                    let v = codes[i + 2]
                    let col: UInt8? = v < 16 ? UInt8(v) : nil
                    if c == 38 { attr.fg = col } else { attr.bg = col }
                    i += 2
                } else if i + 4 < codes.count && codes[i + 1] == 2 {
                    i += 4
                }
            default: break
            }
            i += 1
        }
    }

    // MARK: - keys

    /// The bytes a VT100 sends for a key, given AppKit's characters for it
    /// (which already carry Control: Ctrl-C is "\u{3}").
    public static func bytes(forKeyCode code: UInt16, characters: String?) -> [UInt8] {
        switch code {
        case 0x7E: return Array("\u{1B}[A".utf8)
        case 0x7D: return Array("\u{1B}[B".utf8)
        case 0x7C: return Array("\u{1B}[C".utf8)
        case 0x7B: return Array("\u{1B}[D".utf8)
        case 0x73: return Array("\u{1B}[H".utf8)
        case 0x77: return Array("\u{1B}[F".utf8)
        case 0x75: return Array("\u{1B}[3~".utf8)
        case 0x74: return Array("\u{1B}[5~".utf8)
        case 0x79: return Array("\u{1B}[6~".utf8)
        case 0x24, 0x4C: return [13]
        case 0x33: return [0x7F]
        case 0x35: return [0x1B]
        case 0x30: return [9]
        default: break
        }
        guard let s = characters, !s.isEmpty else { return [] }
        // Function keys and the like arrive as private-use characters.
        if let u = s.unicodeScalars.first, (0xF700...0xF8FF).contains(u.value) { return [] }
        return Array(s.utf8)
    }
}
