// SPDX-License-Identifier: GPL-2.0-or-later
//
// The console window: the Chumby's serial console in a terminal view, with
// its scrollback. The same console is on a pseudo-terminal for any other
// terminal program, which "Open in Terminal" opens chumby-term on.

import AppKit
import ChumbyKit
import Combine
import SwiftUI

final class TerminalTextView: NSTextView {
    var send: (([UInt8]) -> Void)?
    var cursor: NSRange?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with e: NSEvent) {
        if e.modifierFlags.contains(.command) { super.keyDown(with: e); return }
        let b = Terminal.bytes(forKeyCode: e.keyCode, characters: e.characters)
        if !b.isEmpty { send?(b) }
    }

    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        // Control keys are the Chumby's, not the window's.
        if window?.firstResponder === self && e.modifierFlags.contains(.control)
            && !e.modifierFlags.contains(.command) {
            keyDown(with: e)
            return true
        }
        return super.performKeyEquivalent(with: e)
    }

    override func paste(_ sender: Any?) {
        guard let s = NSPasteboard.general.string(forType: .string) else { return }
        send?(Array(s.replacingOccurrences(of: "\r\n", with: "\r")
            .replacingOccurrences(of: "\n", with: "\r").utf8))
    }

    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(paste(_:)) { return NSPasteboard.general.string(forType: .string) != nil }
        return super.validateMenuItem(item)
    }
}

@MainActor
final class ConsoleWindowController: NSWindowController, NSWindowDelegate {
    private let session: Session
    private let text: TerminalTextView
    private let scroll: NSScrollView
    private var lineLengths: [Int] = []
    private var watch: AnyCancellable?
    private let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private let bold = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)

    init(session: Session) {
        self.session = session
        scroll = NSTextView.scrollableTextView()
        text = TerminalTextView(frame: .zero)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 440),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        super.init(window: w)
        w.title = "Console"
        w.subtitle = session.ttyPath ?? ""
        w.delegate = self
        w.setFrameAutosaveName("ChumbyConsole")
        w.tabbingMode = .disallowed

        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.usesFindBar = true
        text.isIncrementalSearchingEnabled = true
        text.font = font
        text.textContainerInset = NSSize(width: 6, height: 6)
        text.backgroundColor = .textBackgroundColor
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.send = { [weak session] b in session?.sendToConsole(b) }
        text.setAccessibilityLabel("The Chumby's console")
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        let bar = NSHostingView(rootView: ConsoleBar(tty: session.ttyPath, open: { [weak self] in self?.openInTerminal() }))
        let content = NSView()
        for v in [scroll, bar] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.topAnchor.constraint(equalTo: scroll.bottomAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        w.contentView = content

        lineLengths = []
        text.textStorage?.setAttributedString(NSAttributedString())
        render(full: true)
        watch = session.$consoleVersion.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in
            self?.render(full: false)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        if window?.isVisible != true {
            window?.center()
            if let f = window?.frame, f.origin == .zero { window?.center() }
        }
        showWindow(nil)
        window?.makeFirstResponder(text)
        // An Enter shows a fresh prompt, as chumby-term does.
        if lineLengths.count <= 1 { session.sendToConsole([13]) }
    }

    // MARK: - drawing the terminal

    private func render(full: Bool) {
        guard let storage = text.textStorage else { return }
        let term = session.terminal
        var (dropped, from) = term.takeChanges()
        if full { dropped = 0; from = 0; lineLengths = []; storage.setAttributedString(NSAttributedString()) }
        let atBottom = isScrolledToBottom
        storage.beginEditing()
        if dropped > 0 {
            let n = min(dropped, lineLengths.count)
            let len = lineLengths[0..<n].reduce(0, +)
            storage.deleteCharacters(in: NSRange(location: 0, length: min(len, storage.length)))
            lineLengths.removeFirst(n)
        }
        from = min(from, lineLengths.count)
        let start = lineLengths[0..<from].reduce(0, +)
        storage.deleteCharacters(in: NSRange(location: start, length: storage.length - start))
        lineLengths.removeSubrange(from...)
        let out = NSMutableAttributedString()
        for i in from..<term.lines.count {
            let before = out.length
            append(line: i, to: out, last: i == term.lines.count - 1)
            lineLengths.append(out.length - before)
        }
        storage.append(out)
        storage.endEditing()
        if atBottom { text.scrollToEndOfDocument(nil) }
    }

    private var isScrolledToBottom: Bool {
        let visible = scroll.contentView.bounds
        return visible.maxY >= text.frame.height - 30
    }

    private func append(line i: Int, to out: NSMutableAttributedString, last: Bool) {
        let term = session.terminal
        var cells = term.lines[i]
        let cursorHere = i == term.cursorLine
        if cursorHere {
            while cells.count <= term.cursorCol { cells.append(TermCell(ch: " ", attr: TermAttr())) }
        }
        var run = ""
        var runAttr: TermAttr?
        var runCursor = false
        func flush() {
            guard !run.isEmpty, let a = runAttr else { return }
            out.append(NSAttributedString(string: run, attributes: attributes(a, cursor: runCursor)))
            run = ""
        }
        for (c, cell) in cells.enumerated() {
            let isCursor = cursorHere && c == term.cursorCol
            if cell.attr != runAttr || isCursor != runCursor {
                flush()
                runAttr = cell.attr
                runCursor = isCursor
            }
            run.append(cell.ch)
        }
        flush()
        if !last { out.append(NSAttributedString(string: "\n", attributes: [.font: font])) }
    }

    private func attributes(_ a: TermAttr, cursor: Bool) -> [NSAttributedString.Key: Any] {
        var fg = a.fg.map(Self.color) ?? NSColor.textColor
        var bg = a.bg.map(Self.color)
        if a.bold, let f = a.fg, f < 8 { fg = Self.color(f + 8) }
        if a.inverse != cursor {
            let f = fg
            fg = bg ?? NSColor.textBackgroundColor
            bg = f
        }
        var d: [NSAttributedString.Key: Any] = [.font: a.bold ? bold : font, .foregroundColor: fg]
        if let bg { d[.backgroundColor] = bg }
        if a.underline { d[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        return d
    }

    /// The 16 ANSI colours, readable on the light and the dark background.
    static func color(_ i: UInt8) -> NSColor {
        switch i {
        case 0: return NSColor(name: nil) { $0.isDark ? NSColor(white: 0.45, alpha: 1) : .black }
        case 1: return .systemRed
        case 2: return .systemGreen
        case 3: return NSColor(name: nil) { $0.isDark ? .systemYellow : .systemBrown }
        case 4: return .systemBlue
        case 5: return .systemPurple
        case 6: return .systemTeal
        case 7: return NSColor(name: nil) { $0.isDark ? NSColor(white: 0.8, alpha: 1) : NSColor(white: 0.45, alpha: 1) }
        case 8: return .systemGray
        case 9: return .systemPink
        case 10: return .systemMint
        case 11: return .systemYellow
        case 12: return .systemCyan
        case 13: return .systemIndigo
        case 14: return .systemCyan
        default: return .textColor
        }
    }

    // MARK: - other terminals

    private func openInTerminal() {
        guard let tty = session.ttyPath else { return }
        Terminals.open(tty: tty) { [weak self] err in self?.session.say(err) }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        window?.makeFirstResponder(text)
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

struct ConsoleBar: View {
    let tty: String?
    let open: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "cable.connector")
                .foregroundStyle(.secondary)
            if let tty {
                Text("Also a serial port at ") + Text(tty).font(.callout.monospaced())
                Spacer()
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(tty, forType: .string)
                }
                Button { open() } label: { Label("Open in Terminal", systemImage: "terminal") }
            } else {
                Text("The console isn't connected.")
                Spacer()
            }
        }
        .font(.callout)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

/// Opens chumby-term on the console's pseudo-terminal in the user's
/// terminal app: a .command file goes to whichever app opens shell
/// scripts (Terminal, iTerm2...).
enum Terminals {
    @MainActor static func open(tty: String, error report: (String) -> Void) {
        let term = Bundle.main.url(forResource: "chumby-term", withExtension: nil)?.path
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("chumby-console-\(UUID().uuidString.prefix(8)).command")
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        var script = "#!/bin/sh\nrm -f \(q(url.path))\n"
        if let term {
            script += "exec /usr/bin/env python3 \(q(term)) \(q(tty))\n"
        } else {
            script += "exec screen \(q(tty))\n"
        }
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        } catch {
            report("Couldn't open a terminal: \(error.localizedDescription)")
            return
        }
        NSWorkspace.shared.open(url)
    }
}
