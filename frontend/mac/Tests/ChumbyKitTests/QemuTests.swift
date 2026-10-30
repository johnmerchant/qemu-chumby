// SPDX-License-Identifier: GPL-2.0-or-later
//
// Against a real QEMU, when CHUMBY_TEST_QEMU (a qemu-system-arm with the
// chumby-classic machine) and CHUMBY_TEST_KERNEL (a zImage that boots to
// a shell on the screen and on ttymxc0, such as the sideload kernels) are
// set: the screen over VNC matches QMP's screendump, keys typed with the
// Mac's key codes reach the shell, and the top button reaches the board.

import Foundation
import Testing
@testable import ChumbyKit

private let env = ProcessInfo.processInfo.environment

@Suite(.enabled(if: env["CHUMBY_TEST_QEMU"] != nil && env["CHUMBY_TEST_KERNEL"] != nil),
       .serialized)
struct QemuTests {
    final class Watch: @unchecked Sendable {
        let lock = NSLock()
        var text = ""
        func add(_ b: [UInt8]) { lock.lock(); text += String(decoding: b, as: UTF8.self); lock.unlock() }
        func wait(for s: String, _ seconds: Double) -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                lock.lock(); let ok = text.contains(s); lock.unlock()
                if ok { return true }
                usleep(100_000)
            }
            return false
        }
    }

    /// The Mac's key codes for some characters, and whether Shift is down.
    static let keys: [Character: (UInt16, Bool)] = [
        "e": (0x0E, false), "c": (0x08, false), "h": (0x04, false), "o": (0x1F, false),
        "t": (0x11, false), "y": (0x10, false), "p": (0x23, false), "d": (0x02, false),
        "k": (0x28, false), "v": (0x09, false), "m": (0x2E, false), "x": (0x07, false),
        "1": (0x12, false), "0": (0x1D, false), " ": (0x31, false), "-": (0x1B, false), "/": (0x2C, false),
        ">": (0x2F, true), "\r": (0x24, false),
    ]

    @Test func screenKeysAndButton() throws {
        let qemu = env["CHUMBY_TEST_QEMU"]!
        var o = LaunchOptions()
        o.kernel = env["CHUMBY_TEST_KERNEL"]!
        o.audio = "none"
        // Real time: with -icount's clock running ahead, a key held for
        // a moment would repeat.
        o.extra = ["-append", "console=ttymxc0,115200"]
        let f = QemuFeatures.probe(qemu: qemu)
        let dir = try makeSocketDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let cmd = QemuCommand(qemu: qemu, options: o, features: f, dir: dir)
        let args = try cmd.arguments()
        #expect(args.contains("-nic") && args[args.firstIndex(of: "-nic")! + 1] == "none")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: qemu)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        defer { if p.isRunning { p.terminate(); p.waitUntilExit() } }

        let qmp = QMPClient(socket: try UnixSocket.connect(path: cmd.qmpPath))
        try qmp.start()
        let updated = DispatchSemaphore(value: 0)
        let rfb = RFBClient(socket: try UnixSocket.connect(path: cmd.vncPath)) { ev in
            if case .updated = ev { updated.signal() }
        }
        rfb.start()
        let watch = Watch()
        let console = try Console(socket: try UnixSocket.connect(path: cmd.consolePath))
        console.onOutput = { watch.add($0) }
        console.start()
        #expect(console.ttyPath.hasPrefix("/dev/tty"))

        // A machine without a keyboard of its own (no usb-keyboard) gets one.
        let list = try #require(try qmp.call("qom-list", ["path": "/machine"]) as? [[String: Any]])
        if !list.contains(where: { $0["name"] as? String == "usb-keyboard" }) {
            _ = try qmp.call("device_add", ["driver": "usb-kbd"])
        }

        // Booted: the shells' prompt on the console.
        #expect(watch.wait(for: "~ #", 180))
        sleep(3)

        // The screen as VNC has it is the screen as QEMU dumps it (the
        // cursor blinks: the same at least once in a few tries).
        let ppm = (dir as NSString).appendingPathComponent("shot.ppm")
        var differ = -1
        for _ in 0..<8 where differ != 0 {
            _ = try qmp.call("screendump", ["filename": ppm, "format": "ppm"])
            _ = updated.wait(timeout: .now() + 0.3)
            let s = rfb.snapshot()
            let dump = try Data(contentsOf: URL(fileURLWithPath: ppm))
            let (w, h, rgb) = try #require(Self.parsePPM(dump))
            #expect(w == s.width && h == s.height && w == 320 && h == 240)
            #expect(s.pixels.contains { $0 != 0 }, "the screen is blank")
            differ = 0
            for i in 0..<(w * h) where rgb[i * 3] != s.pixels[i * 4 + 2] || rgb[i * 3 + 1] != s.pixels[i * 4 + 1]
                || rgb[i * 3 + 2] != s.pixels[i * 4] {
                differ += 1
            }
        }
        #expect(differ == 0, "\(differ) pixels differ")

        // A first key plugs in the keyboard (usb-keyboard): Return, then
        // time for the guest to take it on.
        for down in [true, false] {
            qmp.sendInput([QMPClient.keyEvent(qcode: KeyMap.qcode(forKeyCode: 0x24)!, down: down)])
            usleep(50_000)
        }
        #expect(watch.wait(for: "USB Keyboard", 20))
        sleep(2)

        // Typed on the screen's keyboard, it runs in the screen's shell,
        // which writes to the serial console where we can read it.
        let before = rfb.snapshot().pixels
        for ch in "echo typed-ok-1 > /dev/ttymxc0\r" {
            guard let (code, shift) = Self.keys[ch] else { Issue.record("no key for \(ch)"); break }
            let q = try #require(KeyMap.qcode(forKeyCode: code))
            if shift { qmp.sendInput([QMPClient.keyEvent(qcode: KeyMap.qcodes[KeyMap.shift]!, down: true)]) }
            // At a typist's pace: the USB keyboard's queue is short.
            qmp.sendInput([QMPClient.keyEvent(qcode: q, down: true)])
            usleep(40_000)
            qmp.sendInput([QMPClient.keyEvent(qcode: q, down: false)])
            if shift { qmp.sendInput([QMPClient.keyEvent(qcode: KeyMap.qcodes[KeyMap.shift]!, down: false)]) }
            usleep(40_000)
        }
        let ran = watch.wait(for: "typed-ok-1", 20)
        #expect(ran, "the typed command didn't run")
        if !ran {
            // For a look: the console and the screen.
            let tmp = NSTemporaryDirectory()
            try? watch.text.write(toFile: tmp + "chumby-test-console.txt", atomically: true, encoding: .utf8)
            _ = try? qmp.call("screendump", ["filename": tmp + "chumby-test-screen.png", "format": "png"])
        }
        #expect(rfb.snapshot().pixels != before, "the screen didn't show the typing")

        // The pen: QEMU takes the events (the guest's reading is the
        // touchscreen driver's business).
        for down in [true, false] {
            _ = try qmp.call("input-send-event",
                             ["events": QMPClient.penEvents(x: 160, y: 120, width: 320, height: 240, down: down)])
        }

        // The top button, on the board.
        _ = try qmp.call("qom-set", ["path": "/machine", "property": "button", "value": true])
        let st = try #require(try qmp.call("query-chumby-state") as? [String: Any])
        #expect(st["button"] as? Bool == true)
        _ = try qmp.call("qom-set", ["path": "/machine", "property": "button", "value": false])

        qmp.send("quit")
        let end = Date().addingTimeInterval(10)
        while p.isRunning && Date() < end { usleep(50_000) }
        #expect(!p.isRunning)
        rfb.stop()
        console.close()
    }

    static func parsePPM(_ d: Data) -> (Int, Int, [UInt8])? {
        let b = [UInt8](d)
        var i = 0
        func token() -> String {
            while i < b.count, b[i] == 0x20 || b[i] == 0x0A || b[i] == 0x0D || b[i] == 0x09 { i += 1 }
            var s = ""
            while i < b.count, !(b[i] == 0x20 || b[i] == 0x0A || b[i] == 0x0D || b[i] == 0x09) {
                s.append(Character(UnicodeScalar(b[i]))); i += 1
            }
            return s
        }
        guard token() == "P6", let w = Int(token()), let h = Int(token()), token() == "255" else { return nil }
        i += 1
        guard b.count - i >= w * h * 3 else { return nil }
        return (w, h, Array(b[i..<(i + w * h * 3)]))
    }
}
