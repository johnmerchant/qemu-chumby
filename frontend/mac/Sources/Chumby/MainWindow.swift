// SPDX-License-Identifier: GPL-2.0-or-later
//
// The app's one window: the start view, or the running Chumby's screen
// with the inspector beside it and the machine's controls in the toolbar.

import AppKit
import ChumbyKit
import Combine
import SwiftUI

extension NSToolbarItem.Identifier {
    static let pause = Self("pause")
    static let button = Self("button")
    static let screenshot = Self("screenshot")
    static let saveState = Self("saveState")
    static let loadState = Self("loadState")
    static let reset = Self("reset")
    static let console = Self("console")
    static let status = Self("status")
}

/// The screen and its bezel.
final class ScreenViewController: NSViewController {
    let container = ScreenContainerView(frame: NSRect(x: 0, y: 0, width: 480, height: 360))
    override func loadView() { view = container }
}

@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate,
                                  NSToolbarItemValidation, NSMenuItemValidation {
    let draft = LaunchDraft()
    private(set) var session: Session?
    private var watch: Set<AnyCancellable> = []
    private var split: NSSplitViewController?
    private var screenVC: ScreenViewController?
    private var inspectorItem: NSSplitViewItem?
    private var console: ConsoleWindowController?
    private var buttonItem: HoldToolbarButton?
    /// The Chumby's screen size in points for each Chumby pixel.
    private var scale: CGFloat = 2
    /// Quit the app when the machine stops (it was started from the command line).
    var quitWhenDone = false
    var onEnded: ((Int32) -> Void)?
    static let inspectorWidth: CGFloat = 280

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 460),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        super.init(window: w)
        w.title = "Chumby"
        w.delegate = self
        w.tabbingMode = .disallowed
        w.titlebarSeparatorStyle = .automatic
        w.toolbarStyle = .unified
        let tb = NSToolbar(identifier: "main")
        tb.delegate = self
        tb.displayMode = .iconOnly
        tb.allowsUserCustomization = false
        w.toolbar = tb
        showWelcome(error: nil)
        w.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - start and stop

    func showWelcome(error: String?) {
        guard let w = window else { return }
        let view = WelcomeView(draft: draft, error: error) { [weak self] o in self?.launch(o) }
        let host = NSHostingController(rootView: view)
        host.sizingOptions = []
        let old = w.frame
        let had = w.contentRect(forFrameRect: old).size
        w.contentViewController = host
        // The machine's controls have no machine to work on yet.
        w.toolbar?.isVisible = false
        w.contentMinSize = NSSize(width: 620, height: 560)
        // At least the start view's size, keeping the window's top left.
        w.setContentSize(NSSize(width: max(740, had.width), height: max(580, had.height)))
        w.setFrameTopLeftPoint(NSPoint(x: old.minX, y: old.maxY))
        w.title = "Chumby"
        w.subtitle = ""
        split = nil
        screenVC = nil
        inspectorItem = nil
        w.toolbar?.validateVisibleItems()
        refreshToolbar()
    }

    func launch(_ o: LaunchOptions) {
        guard session == nil else { return }
        var o = o
        if o.qemu == nil, let q = draft.qemu { o.qemu = q }
        let s = Session(options: o)
        session = s
        console?.close()
        console = nil
        watch = []
        s.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.sessionChanged() }
        }.store(in: &watch)
        showScreen(for: s)
        s.start()
    }

    private func showScreen(for s: Session) {
        guard let w = window else { return }
        let screen = ScreenViewController()
        screen.container.screen.session = s
        s.onFrame = { [weak screen] img in screen?.container.screen.show(img) }
        let split = NSSplitViewController()
        let main = NSSplitViewItem(viewController: screen)
        main.minimumThickness = 240
        split.addSplitViewItem(main)
        let inspector = NSSplitViewItem(inspectorWithViewController: NSHostingController(rootView: InspectorView(session: s)))
        inspector.minimumThickness = Self.inspectorWidth
        inspector.maximumThickness = Self.inspectorWidth
        inspector.canCollapse = true
        split.addSplitViewItem(inspector)
        self.split = split
        screenVC = screen
        inspectorItem = inspector
        w.contentMinSize = NSSize(width: 200, height: 150)
        w.contentViewController = split
        w.toolbar?.isVisible = true
        w.title = s.options.displayName
        w.subtitle = "Starting…"
        scale = s.options.scale.map { CGFloat($0) } ?? realSizeScale(on: w.screen ?? NSScreen.main)
        fitWindow()
        w.makeFirstResponder(screen.container.screen)
        refreshToolbar()
    }

    private func sessionChanged() {
        guard let s = session, let w = window else { return }
        switch s.phase {
        case .starting:
            w.subtitle = "Starting…"
        case .running:
            if s.message == nil {
                w.subtitle = s.running ? "Running · no network" : "Paused"
            } else {
                w.subtitle = s.message!
            }
            if let c = screenVC?.container {
                c.isPaused = !s.running
                if c.aspect != s.screenSize { c.aspect = s.screenSize }
            }
            if !addedToRecents {
                Recents.shared.add(s.options)
                addedToRecents = true
            }
        case .ended(let error):
            ended(error)
            return
        }
        refreshToolbar()
    }

    private var addedToRecents = false

    private func ended(_ error: String?) {
        guard let s = session else { return }
        session = nil
        addedToRecents = false
        watch = []
        console?.close()
        console = nil
        s.onFrame = nil
        if quitWhenDone {
            onEnded?(error == nil ? 0 : 1)
            if let error { FileHandle.standardError.write(Data(("Chumby: " + error + "\n").utf8)) }
            NSApp.terminate(nil)
            return
        }
        showWelcome(error: error)
    }

    // MARK: - sizing

    /// Points per Chumby pixel that make the screen a real Chumby's size
    /// (71 x 53 mm) on this display; 2 if it won't say how big it is.
    func realSizeScale(on screen: NSScreen?) -> CGFloat {
        guard let screen,
              let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else { return 2 }
        let mm = CGDisplayScreenSize(id).width
        guard mm >= 50 else { return 2 }
        let ppmm = screen.frame.width / mm
        guard (50 / 25.4)...(400 / 25.4) ~= ppmm else { return 2 }
        return min(6, max(1, (71.12 * ppmm / 320 * 100).rounded() / 100))
    }

    private var inspectorShown: Bool { inspectorItem.map { !$0.isCollapsed } ?? false }

    /// Sizes the window so the screen is drawn at `scale`.
    private func fitWindow() {
        guard let w = window, let s = session else { return }
        let pad = ScreenContainerView.padding
        let side = inspectorShown ? Self.inspectorWidth + 1 : 0
        let chrome = w.frameRect(forContentRect: .zero).size
        // No bigger than the display: the scale comes down to fit.
        if let vis = (w.screen ?? NSScreen.main)?.visibleFrame {
            let fit = min((vis.width - chrome.width - side - 2 * pad) / s.screenSize.width,
                          (vis.height - chrome.height - 2 * pad) / s.screenSize.height)
            scale = max(0.5, min(scale, fit))
        }
        var size = NSSize(width: s.screenSize.width * scale + 2 * pad + side,
                          height: s.screenSize.height * scale + 2 * pad)
        if inspectorShown { size.height = max(size.height, 520) }
        let old = w.frame
        var frame = w.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: old.minX, y: old.maxY - frame.height)
        if let vis = (w.screen ?? NSScreen.main)?.visibleFrame {
            frame.size.height = min(frame.height, vis.height)
            frame.origin.y = max(vis.minY, min(frame.origin.y, vis.maxY - frame.height))
            frame.origin.x = max(vis.minX, min(frame.origin.x, vis.maxX - frame.width))
        }
        w.setFrame(frame, display: true, animate: false)
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        // With the inspector hidden the window keeps the screen's shape.
        guard let s = session, !inspectorShown, split != nil else { return frameSize }
        let pad = ScreenContainerView.padding
        let top = sender.frame.height - sender.contentRect(forFrameRect: sender.frame).height
        let w = frameSize.width - 2 * pad
        let h = w * s.screenSize.height / s.screenSize.width
        return NSSize(width: frameSize.width, height: h + 2 * pad + top)
    }

    func zoom(by step: Int) {
        let steps: [CGFloat] = [1, 1.5, 2, 2.5, 3, 4, 5, 6]
        let cur = currentScale
        if step > 0 {
            scale = steps.first { $0 > cur + 0.01 } ?? steps.last!
        } else {
            scale = steps.last { $0 < cur - 0.01 } ?? steps.first!
        }
        fitWindow()
    }

    func actualSize() {
        scale = realSizeScale(on: window?.screen)
        fitWindow()
    }

    func pixelSize(_ n: CGFloat) {
        scale = n
        fitWindow()
    }

    private var currentScale: CGFloat {
        guard let c = screenVC?.container, let s = session else { return scale }
        return c.screen.frame.width / s.screenSize.width
    }

    // MARK: - actions

    @objc func togglePause(_ sender: Any?) { session?.togglePause() }
    @objc func resetMachine(_ sender: Any?) { session?.reset() }
    @objc func saveState(_ sender: Any?) { session?.saveState() }
    @objc func loadState(_ sender: Any?) { session?.loadState() }
    @objc func pressButton(_ sender: Any?) { session?.tapButton() }
    @objc func shake(_ sender: Any?) { session?.shake() }
    @objc func copyScreen(_ sender: Any?) { session?.copyScreen() }
    @objc func actualSize(_ sender: Any?) { actualSize() }
    @objc func zoomIn(_ sender: Any?) { zoom(by: 1) }
    @objc func zoomOut(_ sender: Any?) { zoom(by: -1) }
    @objc func pixelScale(_ sender: NSMenuItem) { pixelSize(CGFloat(sender.tag)) }
    @objc func toggleHeadphones(_ sender: Any?) {
        guard let s = session else { return }
        s.setHeadphones(!s.headphones)
    }

    @objc func screenshot(_ sender: Any?) {
        guard let s = session, let w = window else { return }
        let p = NSSavePanel()
        p.allowedContentTypes = [.png]
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        p.nameFieldStringValue = "Chumby \(f.string(from: Date())).png"
        p.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        p.beginSheetModal(for: w) { r in
            if r == .OK, let url = p.url { s.screenshot(to: url) }
        }
    }

    @objc func showConsole(_ sender: Any?) {
        guard let s = session, s.phase == .running else { return }
        if console == nil { console = ConsoleWindowController(session: s) }
        console?.show()
    }

    @objc func toggleInspectorPanel(_ sender: Any?) {
        guard let item = inspectorItem else { return }
        // The screen keeps its size: the window grows or shrinks around it.
        scale = currentScale
        item.isCollapsed.toggle()
        fitWindow()
    }

    @objc func openImages(_ sender: Any?) {
        if session != nil { return }
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = true
        p.message = "Choose a folder with zImage and nand.img, or a kernel"
        p.prompt = "Start"
        if p.runModal() == .OK, let url = p.url {
            var dir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &dir)
            launch(dir.boolValue ? draft.options(images: url.path) : draft.options(kernel: url.path))
        }
    }

    @objc func stopMachine(_ sender: Any?) {
        guard let s = session else { return }
        s.quit {}
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        validate(item.action, item)
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        validate(item.action, nil)
    }

    private func validate(_ action: Selector?, _ menuItem: NSMenuItem?) -> Bool {
        let running = session?.phase == .running
        switch action {
        case #selector(togglePause(_:)):
            menuItem?.title = session?.running == false ? "Resume" : "Pause"
            return running
        case #selector(saveState(_:)), #selector(loadState(_:)):
            return running && session?.canSaveState == true
        case #selector(toggleHeadphones(_:)):
            menuItem?.state = session?.headphones == true ? .on : .off
            return running && session?.has("headphones") == true
        case #selector(pressButton(_:)): return running && session?.has("button") == true
        case #selector(shake(_:)): return running && session?.has("accel-x") == true
        case #selector(resetMachine(_:)), #selector(screenshot(_:)), #selector(copyScreen(_:)),
             #selector(stopMachine(_:)):
            return running
        case #selector(showConsole(_:)): return running && session?.ttyPath != nil
        case #selector(actualSize(_:)), #selector(zoomIn(_:)), #selector(zoomOut(_:)),
             #selector(pixelScale(_:)):
            return split != nil
        case #selector(toggleInspectorPanel(_:)):
            menuItem?.title = inspectorShown ? "Hide Inspector" : "Show Inspector"
            return split != nil
        case #selector(openImages(_:)): return session == nil
        default: return true
        }
    }

    // MARK: - the toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.pause, .button, .flexibleSpace, .screenshot, .saveState, .loadState, .reset,
         .console, .flexibleSpace, .toggleInspector]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        func item(_ label: String, _ symbol: String, _ action: Selector, _ tip: String) -> NSToolbarItem {
            let i = NSToolbarItem(itemIdentifier: id)
            i.label = label
            i.paletteLabel = label
            i.toolTip = tip
            i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            i.target = self
            i.action = action
            i.isBordered = true
            return i
        }
        switch id {
        case .pause: return item("Pause", "pause.fill", #selector(togglePause(_:)), "Pause or resume the Chumby (⌘P)")
        case .screenshot: return item("Screenshot", "camera", #selector(screenshot(_:)), "Save the screen as a PNG (⇧⌘S)")
        case .saveState: return item("Save State", "square.and.arrow.down", #selector(saveState(_:)),
                                     "Save the running machine in its state folder (start with a state folder to use this)")
        case .loadState: return item("Restore State", "clock.arrow.circlepath", #selector(loadState(_:)),
                                     "Go back to the saved state")
        case .reset: return item("Reset", "arrow.counterclockwise", #selector(resetMachine(_:)), "Reset the Chumby")
        case .console: return item("Console", "terminal", #selector(showConsole(_:)), "The serial console (⌘K)")
        case .toggleInspector:
            let i = item("Inspector", "sidebar.right", #selector(toggleInspectorPanel(_:)), "Show or hide the inspector (⌥⌘I)")
            return i
        case .button:
            let b = HoldToolbarButton()
            b.onChange = { [weak self] down in self?.session?.setButton(down) }
            buttonItem = b
            let i = NSToolbarItem(itemIdentifier: id)
            i.view = b
            i.label = "Top Button"
            i.toolTip = "The top button: held while the mouse is down on it (or F12 on the screen)"
            return i
        default: return nil
        }
    }

    private func refreshToolbar() {
        guard let tb = window?.toolbar else { return }
        let running = session?.phase == .running
        for i in tb.items {
            if i.itemIdentifier == .pause {
                let paused = session?.running == false
                i.image = NSImage(systemSymbolName: paused ? "play.fill" : "pause.fill", accessibilityDescription: nil)
                i.label = paused ? "Resume" : "Pause"
            }
        }
        buttonItem?.isEnabled = running && session?.has("button") == true
        buttonItem?.isDown = session?.buttonDown == true
        tb.validateVisibleItems()
    }

    // MARK: - the window

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApp.terminate(nil)
        return false
    }
}

/// The toolbar's top button: down while the mouse is.
final class HoldToolbarButton: NSButton {
    var onChange: ((Bool) -> Void)?
    var isDown = false { didSet { state = isDown ? .on : .off } }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 40, height: 28))
        bezelStyle = .toolbar
        setButtonType(.pushOnPushOff)
        image = NSImage(systemSymbolName: "button.programmable", accessibilityDescription: "Top button")
        imagePosition = .imageOnly
        setAccessibilityLabel("Top button")
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with e: NSEvent) {
        guard isEnabled else { return }
        onChange?(true)
        state = .on
        highlight(true)
        // Track until the mouse comes up, wherever it goes.
        while let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]), next.type != .leftMouseUp {}
        highlight(false)
        state = .off
        onChange?(false)
    }

    override func accessibilityPerformPress() -> Bool {
        onChange?(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.onChange?(false) }
        return true
    }
}
