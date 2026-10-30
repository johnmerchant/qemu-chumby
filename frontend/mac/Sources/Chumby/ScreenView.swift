// SPDX-License-Identifier: GPL-2.0-or-later
//
// The Chumby's screen: the frames VNC brings, drawn crisp (nearest
// neighbour) at any size. The mouse on it is the pen; keys typed while it
// has the focus go to the Chumby, by their position on the keyboard, as
// QEMU's own Cocoa window sends them. Command shortcuts stay the app's.

import AppKit
import ChumbyKit
import SwiftUI

final class ScreenView: NSView {
    weak var session: Session?
    private var held = Set<UInt16>()
    private var penDown = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer!.magnificationFilter = .nearest
        layer!.minificationFilter = .trilinear
        layer!.contentsGravity = .resize
        layer!.backgroundColor = NSColor.black.cgColor
        focusRingType = .exterior
        setAccessibilityRole(.image)
        setAccessibilityLabel("The Chumby's screen")
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { bounds.fill() }

    func show(_ image: CGImage) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contents = image
        CATransaction.commit()
    }

    // MARK: - the pen

    private func chumbyPoint(_ e: NSEvent) -> (Double, Double) {
        let p = convert(e.locationInWindow, from: nil)
        let size = session?.screenSize ?? CGSize(width: 320, height: 240)
        return (Double(p.x / max(1, bounds.width) * size.width),
                Double(p.y / max(1, bounds.height) * size.height))
    }

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        let (x, y) = chumbyPoint(e)
        penDown = true
        session?.pen(x: x, y: y, down: true)
    }

    override func mouseDragged(with e: NSEvent) {
        guard penDown else { return }
        let (x, y) = chumbyPoint(e)
        session?.pen(x: x, y: y, down: nil)
    }

    override func mouseUp(with e: NSEvent) {
        guard penDown else { return }
        penDown = false
        let (x, y) = chumbyPoint(e)
        session?.pen(x: x, y: y, down: false)
    }

    // MARK: - keys

    override func keyDown(with e: NSEvent) {
        if e.modifierFlags.contains(.command) { super.keyDown(with: e); return }
        guard let q = KeyMap.qcode(forKeyCode: e.keyCode) else { return }
        // The guest's keyboard repeats keys itself.
        if e.isARepeat || held.contains(e.keyCode) { return }
        held.insert(e.keyCode)
        session?.key(q, down: true)
    }

    override func keyUp(with e: NSEvent) {
        guard held.remove(e.keyCode) != nil, let q = KeyMap.qcode(forKeyCode: e.keyCode) else { return }
        session?.key(q, down: false)
    }

    override func flagsChanged(with e: NSEvent) {
        let code = e.keyCode
        // Command is the Mac's: it never reaches the Chumby.
        if code == KeyMap.command || code == KeyMap.rightCommand || code == KeyMap.function { return }
        guard let q = KeyMap.qcode(forKeyCode: code) else { return }
        if code == KeyMap.capsLock {
            // macOS reports Caps Lock's state, not the key: press and release.
            session?.key(q, down: true)
            session?.key(q, down: false)
            return
        }
        // Down or up, from the flags for that very key (left or right).
        let down: Bool
        if let bit = Self.deviceBits[code] {
            down = e.modifierFlags.rawValue & bit != 0
        } else {
            down = !held.contains(code)
        }
        if down && !held.contains(code) {
            held.insert(code)
            session?.key(q, down: true)
        } else if !down && held.contains(code) {
            held.remove(code)
            session?.key(q, down: false)
        }
    }

    /// IOKit's device-dependent modifier bits (NX_DEVICE*KEYMASK).
    static let deviceBits: [UInt16: UInt] = [
        KeyMap.control: 0x1, KeyMap.shift: 0x2, KeyMap.rightShift: 0x4,
        KeyMap.option: 0x20, KeyMap.rightOption: 0x40, KeyMap.rightControl: 0x2000,
    ]

    // Shortcuts with Command go to the menus; without, they are the Chumby's
    // keys (Control-C, Escape...), not the window's.
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        if window?.firstResponder === self && !e.modifierFlags.contains(.command) {
            keyDown(with: e)
            return true
        }
        return super.performKeyEquivalent(with: e)
    }

    /// Lets go of every key held, when the focus leaves: no key stays down
    /// in the Chumby while the Mac types elsewhere.
    func releaseAll() {
        for code in held {
            if let q = KeyMap.qcode(forKeyCode: code) { session?.key(q, down: false) }
        }
        held.removeAll()
        if penDown {
            penDown = false
            session?.pen(x: 0, y: 0, down: false)
        }
    }

    override func resignFirstResponder() -> Bool {
        releaseAll()
        return super.resignFirstResponder()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        NotificationCenter.default.removeObserver(self)
        if let newWindow {
            NotificationCenter.default.addObserver(self, selector: #selector(windowResigned),
                                                   name: NSWindow.didResignKeyNotification, object: newWindow)
        }
    }

    @objc private func windowResigned() { releaseAll() }
}

/// The screen in its bezel: centred at the largest size that keeps its
/// shape, with the paused banner over it.
final class ScreenContainerView: NSView {
    static let padding: CGFloat = 14
    let screen = ScreenView(frame: .zero)
    private let paused: NSHostingView<PausedBadge>
    var aspect: CGSize = CGSize(width: 320, height: 240) { didSet { needsLayout = true } }

    override init(frame: NSRect) {
        paused = NSHostingView(rootView: PausedBadge())
        super.init(frame: frame)
        wantsLayer = true
        addSubview(screen)
        addSubview(paused)
        paused.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = NSColor(name: nil) { a in
            a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(white: 0.11, alpha: 1) : NSColor(white: 0.86, alpha: 1)
        }.cgColor
    }

    var isPaused = false {
        didSet { paused.isHidden = !isPaused; screen.alphaValue = isPaused ? 0.55 : 1 }
    }

    func screenRect(in r: NSRect) -> NSRect {
        let pad = Self.padding
        let avail = r.insetBy(dx: pad, dy: pad)
        guard avail.width > 0, avail.height > 0 else { return .zero }
        let s = min(avail.width / aspect.width, avail.height / aspect.height)
        // Whole device pixels when that's close: crisper, no shimmer.
        let scale = window?.backingScaleFactor ?? 2
        let w = (aspect.width * s * scale).rounded(.down) / scale
        let h = (aspect.height * s * scale).rounded(.down) / scale
        return NSRect(x: ((r.width - w) / 2 * scale).rounded() / scale,
                      y: ((r.height - h) / 2 * scale).rounded() / scale, width: w, height: h)
    }

    override func layout() {
        super.layout()
        screen.frame = screenRect(in: bounds)
        let size = paused.fittingSize
        paused.frame = NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.midY - size.height / 2,
                              width: size.width, height: size.height)
    }
}

struct PausedBadge: View {
    var body: some View {
        Label("Paused", systemImage: "pause.fill")
            .font(.title3.weight(.semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .accessibilityLabel("The Chumby is paused")
    }
}
