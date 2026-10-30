// SPDX-License-Identifier: GPL-2.0-or-later
//
// Chumby.app: a Chumby Classic, emulated by QEMU's chumby-classic machine,
// in a native Mac window. Takes chumby-emu's options:
//
//     Chumby IMAGES
//     Chumby --kernel zImage [--nand nand.img] [--state DIR] [--fast] [-- QEMU ARGS]
//
// and with none, opens the start window.

import AppKit
import ChumbyKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var main: MainWindowController!
    var pending: LaunchOptions?
    var fromCommandLine = false
    var exitStatus: Int32 = 0
    private var signals: [DispatchSourceSignal] = []

    func applicationWillFinishLaunching(_ n: Notification) {
        main = MainWindowController()
        NSApp.mainMenu = Menus.make()
        // The machine's commands reach the main window from any window
        // (the console's too).
        Menus.target(NSApp.mainMenu!, to: main)
        main.onEnded = { [weak self] status in self?.exitStatus = status }
        // A SIGINT or SIGTERM (Ctrl-C in the terminal that ran chumby-emu)
        // quits like the menu does, taking QEMU with it.
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            // Not from inside the dispatch block: terminating waits for
            // QEMU in a nested run loop, which a main-queue block would stall.
            src.setEventHandler { RunLoop.main.perform(inModes: [.default]) { NSApp.terminate(nil) } }
            src.resume()
            signals.append(src)
        }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        main.showWindow(nil)
        NSApp.activate()
        if let o = pending {
            main.quitWhenDone = fromCommandLine
            main.launch(o)
        }
    }

    /// Folders and kernels dropped on the Dock icon or opened with the app.
    func application(_ app: NSApplication, open urls: [URL]) {
        guard !fromCommandLine, let url = urls.first, main?.session == nil else { return }
        var dir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &dir)
        let o = dir.boolValue ? main.draft.options(images: url.path) : main.draft.options(kernel: url.path)
        main.launch(o)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let s = main?.session else { return .terminateNow }
        s.quit { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    func applicationWillTerminate(_ n: Notification) {
        main?.session?.killNow()
        if fromCommandLine { exit(exitStatus) }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: - menu actions the window doesn't take

    @objc func showHelp(_ sender: Any?) {
        let a = NSAlert()
        a.messageText = "Chumby"
        a.informativeText = """
            The mouse on the screen is the pen. Click the screen, then type: keys go to the \
            Chumby's USB keyboard. F12 is the top button. Command shortcuts stay the Mac's.

            The emulated Chumby never has a network.

            From a terminal: Chumby IMAGES, or Chumby --kernel zImage [--nand nand.img] \
            [--state DIR] [--fast] [-- QEMU ARGS]; chumby-emu runs this app on macOS.
            """
        a.runModal()
    }
}

enum Menus {
    @MainActor static func target(_ menu: NSMenu, to t: MainWindowController) {
        for i in menu.items {
            if let sub = i.submenu { target(sub, to: t) }
            if let a = i.action, MainWindowController.instancesRespond(to: a),
               !NSWindowController.instancesRespond(to: a) {
                i.target = t
            }
        }
    }

    @MainActor static func make() -> NSMenu {
        let bar = NSMenu()
        func sub(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
            let m = NSMenu(title: title)
            items.forEach(m.addItem)
            let host = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            host.submenu = m
            bar.addItem(host)
            return m
        }
        func item(_ t: String, _ a: Selector?, _ k: String = "", _ mods: NSEvent.ModifierFlags = .command,
                  symbol: String? = nil, tag: Int = 0) -> NSMenuItem {
            let i = NSMenuItem(title: t, action: a, keyEquivalent: k)
            i.keyEquivalentModifierMask = mods
            i.tag = tag
            if let symbol { i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            return i
        }
        let name = "Chumby"
        _ = sub(name, [
            item("About \(name)", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Hide \(name)", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Quit \(name)", #selector(NSApplication.terminate(_:)), "q"),
        ])
        _ = sub("File", [
            item("Open…", #selector(MainWindowController.openImages(_:)), "o", symbol: "folder"),
            .separator(),
            item("Save Screenshot…", #selector(MainWindowController.screenshot(_:)), "s", [.command, .shift], symbol: "camera"),
            .separator(),
            item("Stop Chumby", #selector(MainWindowController.stopMachine(_:)), "w", [.command, .shift], symbol: "stop.fill"),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
        ])
        _ = sub("Edit", [
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            item("Find…", #selector(NSTextView.performFindPanelAction(_:)), "f", tag: Int(NSFindPanelAction.showFindPanel.rawValue)),
        ])
        _ = sub("View", [
            item("Actual Size", #selector(MainWindowController.actualSize(_:)), "0"),
            item("Zoom In", #selector(MainWindowController.zoomIn(_:)), "+"),
            item("Zoom Out", #selector(MainWindowController.zoomOut(_:)), "-"),
            item("1 Point per Pixel", #selector(MainWindowController.pixelScale(_:)), "1", tag: 1),
            item("2 Points per Pixel", #selector(MainWindowController.pixelScale(_:)), "2", tag: 2),
            item("3 Points per Pixel", #selector(MainWindowController.pixelScale(_:)), "3", tag: 3),
            .separator(),
            item("Show Inspector", #selector(MainWindowController.toggleInspectorPanel(_:)), "i", [.command, .option]),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ])
        _ = sub("Chumby", [
            item("Pause", #selector(MainWindowController.togglePause(_:)), "p", symbol: "pause"),
            item("Reset", #selector(MainWindowController.resetMachine(_:)), "r", [.command, .option], symbol: "arrow.counterclockwise"),
            .separator(),
            item("Press Top Button", #selector(MainWindowController.pressButton(_:)), "b", symbol: "button.programmable"),
            item("Shake", #selector(MainWindowController.shake(_:)), "k", [.command, .shift], symbol: "iphone.gen1.radiowaves.left.and.right"),
            item("Headphones Plugged In", #selector(MainWindowController.toggleHeadphones(_:)), "h", [.command, .shift], symbol: "headphones"),
            .separator(),
            item("Save State", #selector(MainWindowController.saveState(_:)), "s", [.command, .option], symbol: "square.and.arrow.down"),
            item("Restore State", #selector(MainWindowController.loadState(_:)), "r", [.command, .option, .shift], symbol: "clock.arrow.circlepath"),
            .separator(),
            item("Copy Screen", #selector(MainWindowController.copyScreen(_:)), "c", [.command, .shift], symbol: "doc.on.doc"),
            item("Console", #selector(MainWindowController.showConsole(_:)), "k", symbol: "terminal"),
        ])
        let window = sub("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
            .separator(),
            item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))),
        ])
        NSApp.windowsMenu = window
        let help = sub("Help", [item("Chumby Help", #selector(AppDelegate.showHelp(_:)), "?")])
        NSApp.helpMenu = help
        return bar
    }
}

setvbuf(stdout, nil, _IOLBF, 0)
let args = Array(CommandLine.arguments.dropFirst())
var options: LaunchOptions?
do {
    let o = try LaunchOptions.parse(args)
    options = o.isEmpty ? nil : o
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(args.contains("--help") || args.contains("-h") ? 0 : 2)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    delegate.pending = options
    delegate.fromCommandLine = options != nil
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
