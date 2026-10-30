// SPDX-License-Identifier: GPL-2.0-or-later
//
// The RFB and QMP clients against fake servers on socketpairs, the
// console's terminal, and the QEMU command line.

import Foundation
import Testing
@testable import ChumbyKit

func be16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 0xff), UInt8(v & 0xff)] }
func be32(_ v: Int) -> [UInt8] {
    let u = UInt32(bitPattern: Int32(truncatingIfNeeded: v))
    return [UInt8(u >> 24), UInt8(u >> 16 & 0xff), UInt8(u >> 8 & 0xff), UInt8(u & 0xff)]
}

final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ v: T) { value = v }
}

@Suite struct RFBTests {
    @Test func handshakeAndRawUpdate() throws {
        let (client, server) = UnixSocket.pair()
        let updated = DispatchSemaphore(value: 0)
        let rfb = RFBClient(socket: client) { ev in
            if case .updated = ev { updated.signal() }
        }
        rfb.start()
        let r = ByteReader(server)
        try server.write("RFB 003.008\n")
        #expect(try r.bytes(12) == Array("RFB 003.008\n".utf8))
        try server.write([1, 1]) // one security type: None
        #expect(try r.u8() == 1)
        try server.write(be32(0))
        #expect(try r.u8() == 1) // shared
        let name = Array("Chumby".utf8)
        try server.write(be16(4) + be16(2) + [UInt8](repeating: 0, count: 16) + be32(name.count) + name)
        // SetPixelFormat: 32 bpp, little-endian, red at 16.
        let pf = try r.bytes(20)
        #expect(pf[0] == 0 && pf[4] == 32 && pf[6] == 0 && pf[7] == 1 && pf[14] == 16)
        // SetEncodings: raw and DesktopSize.
        let enc = try r.bytes(4)
        #expect(enc[0] == 2 && enc[3] == 2)
        #expect(try r.bytes(8) == be32(0) + be32(-223))
        // The first request is for the whole screen.
        #expect(try r.bytes(10) == [3, 0, 0, 0, 0, 0] + be16(4) + be16(2))

        // A 2x1 raw rectangle at (1, 1).
        let px: [UInt8] = [0x10, 0x20, 0x30, 0, 0x40, 0x50, 0x60, 0]
        try server.write([0, 0] + be16(1) + be16(1) + be16(1) + be16(2) + be16(1) + be32(0) + px)
        #expect(updated.wait(timeout: .now() + 5) == .success)
        let s = rfb.snapshot()
        #expect(s.width == 4 && s.height == 2)
        #expect(Array(s.pixels[20..<28]) == px)
        #expect(s.pixels[0..<20].allSatisfy { $0 == 0 })
        // Then incremental requests.
        #expect(try r.bytes(10) == [3, 1, 0, 0, 0, 0] + be16(4) + be16(2))
        #expect(rfb.name == "Chumby")

        // DesktopSize, then a colour map and a bell, which are skipped.
        try server.write([0, 0] + be16(1) + be16(0) + be16(0) + be16(3) + be16(3) + be32(-223))
        #expect(updated.wait(timeout: .now() + 5) == .success)
        #expect(rfb.snapshot().width == 3)
        _ = try r.bytes(10)
        try server.write([1, 0] + be16(0) + be16(1) + [UInt8](repeating: 0, count: 6) + [2])
        try server.write([0, 0] + be16(1) + be16(0) + be16(0) + be16(1) + be16(1) + be32(0) + [1, 2, 3, 0])
        #expect(updated.wait(timeout: .now() + 5) == .success)
        #expect(Array(rfb.snapshot().pixels[0..<4]) == [1, 2, 3, 0])
        rfb.stop()
        server.close()
    }

    @Test func refusesPasswords() throws {
        let (client, server) = UnixSocket.pair()
        let closed = DispatchSemaphore(value: 0)
        let err = Box<Error?>(nil)
        let rfb = RFBClient(socket: client) { ev in
            if case .closed(let e) = ev { err.value = e; closed.signal() }
        }
        rfb.start()
        try server.write("RFB 003.008\n")
        try server.write([1, 2]) // VNC authentication only
        #expect(closed.wait(timeout: .now() + 5) == .success)
        #expect("\(err.value!)".contains("password"))
        server.close()
    }
}

@Suite struct QMPTests {
    func greet(_ server: UnixSocket, _ r: ByteReader) throws {
        try server.write(#"{"QMP": {"version": {}, "capabilities": []}}"# + "\r\n")
        let caps = try JSONSerialization.jsonObject(with: Data(try r.line())) as! [String: Any]
        #expect(caps["execute"] as? String == "qmp_capabilities")
        try server.write(#"{"return": {}}"# + "\r\n")
    }

    @Test func commandsRepliesAndEvents() throws {
        let (client, server) = UnixSocket.pair()
        let qmp = QMPClient(socket: client)
        let r = ByteReader(server)
        let events = Box<[String]>([])
        let gotEvent = DispatchSemaphore(value: 0)
        qmp.onEvent = { name, _ in events.value.append(name); gotEvent.signal() }
        let t = Thread { try? greet(server, r) }
        t.start()
        try qmp.start()

        // Two commands in flight; replies out of order find their callers,
        // with an event between them.
        let a = Box<QMPClient.Reply?>(nil), b = Box<QMPClient.Reply?>(nil)
        let done = DispatchSemaphore(value: 0)
        qmp.send("query-status") { a.value = $0; done.signal() }
        qmp.qomSet("button", true) { b.value = $0; done.signal() }
        let m1 = try JSONSerialization.jsonObject(with: Data(try r.line())) as! [String: Any]
        let m2 = try JSONSerialization.jsonObject(with: Data(try r.line())) as! [String: Any]
        #expect(m1["execute"] as? String == "query-status")
        #expect(m2["execute"] as? String == "qom-set")
        let args = m2["arguments"] as! [String: Any]
        #expect(args["path"] as? String == "/machine" && args["property"] as? String == "button")
        #expect(args["value"] as? Bool == true)
        let id1 = m1["id"] as! Int, id2 = m2["id"] as! Int
        try server.write(#"{"error": {"class": "GenericError", "desc": "nope"}, "id": \#(id2)}"# + "\n")
        try server.write(#"{"event": "STOP", "data": {}, "timestamp": {}}"# + "\n")
        try server.write(#"{"return": {"running": true, "status": "running"}, "id": \#(id1)}"# + "\n")
        #expect(done.wait(timeout: .now() + 5) == .success)
        #expect(done.wait(timeout: .now() + 5) == .success)
        #expect(gotEvent.wait(timeout: .now() + 5) == .success)
        let st = try #require(try a.value?.get() as? [String: Any])
        #expect(st["running"] as? Bool == true)
        if case .failure(let e) = b.value! { #expect(e.description == "nope") } else { Issue.record("no error") }
        #expect(events.value == ["STOP"])

        // A synchronous call, then the machine quits under a pending one.
        let reply = Thread {
            if let m = try? JSONSerialization.jsonObject(with: Data(try! r.line())) as? [String: Any],
               let id = m["id"] as? Int {
                try? server.write(#"{"return": 42, "id": \#(id)}"# + "\n")
            }
            _ = try? r.line()
            server.close()
        }
        reply.start()
        #expect(try qmp.call("qom-get", ["path": "/machine", "property": "accel-x"]) as? Int == 42)
        #expect(throws: QMPError.self) { try qmp.call("stop") }
        #expect(qmp.isClosed)
    }

    @Test func penAndKeyEvents() {
        let ev = QMPClient.penEvents(x: 160, y: 240, width: 320, height: 240, down: true)
        #expect(ev.count == 3)
        #expect((ev[0]["data"] as! [String: Any])["value"] as? Int == 16384)
        #expect((ev[1]["data"] as! [String: Any])["value"] as? Int == 32767)
        #expect((ev[2]["data"] as! [String: Any])["button"] as? String == "left")
        #expect(QMPClient.penEvents(x: -5, y: 0, width: 320, height: 240, down: nil).count == 2)
        let k = QMPClient.keyEvent(qcode: "a", down: false)
        let data = k["data"] as! [String: Any]
        #expect(data["down"] as? Bool == false)
        #expect((data["key"] as! [String: Any])["data"] as? String == "a")
        #expect(KeyMap.qcode(forKeyCode: 0x24) == "ret")
        #expect(KeyMap.qcode(forKeyCode: 0x00) == "a")
        #expect(KeyMap.qcode(forKeyCode: 0x6F) == "f12")
    }
}

@Suite struct TerminalTests {
    @Test func textAndLineEditing() {
        let t = Terminal(cols: 12, rows: 3)
        t.feed("~ # echo hi\r\nhi\r\n~ # ")
        #expect(t.plainText == "~ # echo hi\nhi\n~ #")
        // Backspace over a character, then erase to the end of the line.
        t.feed("ab\u{8}\u{1B}[K")
        #expect(t.text(line: 2) == "~ # a")
        // Wrap at the last column.
        t.feed("\r\n0123456789abX")
        #expect(t.text(line: 3) == "0123456789ab")
        #expect(t.text(line: 4) == "X")
    }

    @Test func clearAndColours() {
        let t = Terminal(cols: 20, rows: 4)
        t.feed("one\r\ntwo\r\n\u{1B}[H\u{1B}[2J\u{1B}[1;32mgreen\u{1B}[0m plain")
        let l = t.lines[t.cursorLine]
        #expect(String(l.map(\.ch)) == "green plain")
        #expect(l[0].attr.fg == 2 && l[0].attr.bold)
        #expect(l[6].attr == TermAttr())
        // What was on the screen stays in the scrollback.
        #expect(t.plainText.hasPrefix("one\ntwo"))
        // Positioning, and an OSC title, dropped.
        t.feed("\u{1B}]0;title\u{7}\u{1B}[2;3HX")
        #expect(t.text(line: t.screenTop + 1).hasPrefix("  X"))
        // UTF-8 split across feeds.
        t.feed([0xC3]); t.feed([0xA9])
        #expect(t.text(line: t.screenTop + 1).hasPrefix("  X\u{e9}"))
    }

    @Test func keys() {
        #expect(Terminal.bytes(forKeyCode: 0x24, characters: "\r") == [13])
        #expect(Terminal.bytes(forKeyCode: 0x7E, characters: "\u{F700}") == Array("\u{1B}[A".utf8))
        #expect(Terminal.bytes(forKeyCode: 0x08, characters: "\u{3}") == [3])
        #expect(Terminal.bytes(forKeyCode: 0x7A, characters: "\u{F704}") == [])
    }
}

@Suite struct LaunchTests {
    @Test func parseOptions() throws {
        let o = try LaunchOptions.parse(["--kernel", "k", "--fast", "--state=s", "--", "-append", "x"])
        #expect(o.kernel == "k" && o.fast && o.state == "s" && o.extra == ["-append", "x"])
        let i = try LaunchOptions.parse(["imgs", "--scale", "2"])
        #expect(i.images == "imgs" && i.scale == 2 && i.kernelPath == "imgs/zImage")
        #expect(throws: LaunchError.self) { try LaunchOptions.parse(["--bogus"]) }
    }

    @Test func alwaysNoNetwork() throws {
        var o = LaunchOptions()
        o.kernel = "/k"
        o.nand = "/n.img"
        var f = QemuFeatures()
        f.audioDrivers = ["coreaudio", "none"]
        f.machineOptions = ["audiodev"]
        var c = QemuCommand(qemu: "/q", options: o, features: f, dir: "/tmp/x")
        let a = try c.arguments()
        let nic = try #require(a.firstIndex(of: "-nic"))
        #expect(a[nic + 1] == "none")
        #expect(a.starts(with: ["-M", "chumby-classic,audiodev=snd0"]))
        #expect(a.contains("unix:/tmp/x/vnc"))
        #expect(a.contains("if=mtd,file=/n.img,format=raw,snapshot=on"))
        for bad in ["-netdev", "-nic", "-net", "--netdev", "-display"] {
            c.options.extra = [bad, "user"]
            #expect(throws: LaunchError.self) { try c.arguments() }
        }
        c.options.extra = []
        c.overlay = "/s/nand.qcow2"
        c.resume = true
        c.options.fast = true
        let s = try c.arguments()
        #expect(s.contains("if=mtd,file=/s/nand.qcow2,format=qcow2"))
        #expect(s.contains("chumby-fast") && s.contains("-icount"))
        c.options.link = "/tmp/link.sock"
        let l = try c.arguments()
        #expect(l.contains("socket,id=link,path=/tmp/link.sock,server=off,reconnect-ms=1000"))
        #expect(l[l.lastIndex(of: "-serial")! + 1] == "chardev:link")
        #expect(try LaunchOptions.parse(["--kernel", "k", "--link", "/tmp/l"]).link == "/tmp/l")
    }

    @Test func tilt() {
        #expect(Tilt.upright.gravity == [0, 0, 1000])
        #expect(Tilt(pitch: 0, roll: 90).gravity == [1000, 0, 0])
        #expect(Tilt(gravity: [0, 1000, 0]).pitch == 90)
        #expect(Tilt.fromMac(x: 0, y: 0, z: -1) == [0, 0, 1000])
    }
}
