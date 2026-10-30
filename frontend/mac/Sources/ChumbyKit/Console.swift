// SPDX-License-Identifier: GPL-2.0-or-later
//
// The Chumby's console (UART1) on QEMU's unix socket, which takes one
// client: this. What the Chumby prints goes to the app's console window
// and to a pseudo-terminal of the app's own (/dev/ttys012), which any
// terminal program opens like a serial port (tio, screen, chumby-term);
// what is typed in either goes to the Chumby, paced for its UART: the
// receive FIFO holds 32 characters, so pieces of 16, 5 ms apart.

import Foundation

public final class Console: @unchecked Sendable {
    public let ttyPath: String
    private let sock: UnixSocket
    private let master: Int32
    private let slave: Int32
    private let out = DispatchQueue(label: "console.out")
    private var seen = ""
    private var activated = false
    /// What the Chumby printed, on the console's thread.
    public var onOutput: (([UInt8]) -> Void)?
    public var onClose: (() -> Void)?

    public init(socket: UnixSocket) throws {
        sock = socket
        var m: Int32 = 0, s: Int32 = 0
        guard openpty(&m, &s, nil, nil, nil) == 0 else { throw SocketError("openpty") }
        master = m
        slave = s
        // The slave end stays open, raw, so the device exists while no
        // terminal has it; output nobody reads is dropped, not queued
        // against the console.
        var t = termios()
        tcgetattr(s, &t)
        cfmakeraw(&t)
        tcsetattr(s, TCSANOW, &t)
        ttyPath = String(cString: ttyname(s))
        let fl = fcntl(m, F_GETFL)
        _ = fcntl(m, F_SETFL, fl | O_NONBLOCK)
    }

    public func start() {
        let r = Thread { [self] in readSocket() }
        r.name = "console"
        r.start()
        let t = Thread { [self] in readTTY() }
        t.name = "console.tty"
        t.start()
    }

    public func send(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        out.async { [sock] in
            var i = 0
            while i < bytes.count {
                let piece = Array(bytes[i..<min(bytes.count, i + 16)])
                if (try? sock.write(piece)) == nil { return }
                i += 16
                if i < bytes.count { usleep(5000) }
            }
        }
    }

    public func send(_ s: String) { send(Array(s.utf8)) }

    public func close() {
        sock.close()
    }

    private func readSocket() {
        while true {
            let d = sock.read(max: 4096)
            if d.isEmpty { break }
            _ = d.withUnsafeBytes { Darwin.write(master, $0.baseAddress, d.count) }
            onOutput?(d)
            watchForActivation(d)
        }
        onClose?()
    }

    /// The stock firmware's init waits for Enter before it starts the
    /// console's shell: give it one, once.
    private func watchForActivation(_ d: [UInt8]) {
        if activated { return }
        seen = String((seen + String(decoding: d, as: UTF8.self)).suffix(200))
        if seen.contains("press Enter to activate") {
            activated = true
            send([13])
        }
    }

    private func readTTY() {
        var buf = [UInt8](repeating: 0, count: 1024)
        while true {
            var p = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
            let r = poll(&p, 1, 500)
            if r < 0 && errno != EINTR { return }
            if r <= 0 { continue }
            let n = buf.withUnsafeMutableBytes { Darwin.read(master, $0.baseAddress, 1024) }
            if n > 0 {
                send(Array(buf[0..<n]))
            } else if n < 0 && errno != EAGAIN && errno != EINTR {
                // EIO while no terminal has the device open: wait for one.
                usleep(200_000)
            }
        }
    }
}
