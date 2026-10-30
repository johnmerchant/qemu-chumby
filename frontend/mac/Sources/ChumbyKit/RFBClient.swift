// SPDX-License-Identifier: GPL-2.0-or-later
//
// A small RFB (VNC) client for QEMU's VNC server on a unix socket: the
// Chumby's screen, 320x240, in raw encoding, which costs nothing to
// decode and little to carry over a local socket. Version 3.8, no
// authentication (the socket lives in a directory only this user can
// reach), DesktopSize for a guest that changes mode. Input goes over QMP,
// not RFB, so this only watches.

import Foundation

public final class RFBClient: @unchecked Sendable {
    public enum Event {
        /// The framebuffer changed: call snapshot() for its pixels.
        case updated
        case resized(width: Int, height: Int)
        case closed(Error?)
    }

    public private(set) var name = ""
    private let sock: UnixSocket
    private let reader: ByteReader
    private let handler: (Event) -> Void
    private let lock = NSLock()
    private var width = 0
    private var height = 0
    /// 32-bit pixels, little-endian 0x00RRGGBB: B, G, R, X in memory.
    private var pixels: [UInt8] = []
    private var stopped = false

    /// handler runs on the client's own thread.
    public init(socket: UnixSocket, handler: @escaping (Event) -> Void) {
        sock = socket
        reader = ByteReader(socket)
        self.handler = handler
    }

    public func start() {
        let t = Thread { [self] in run() }
        t.name = "rfb"
        t.start()
    }

    public func stop() {
        lock.lock(); stopped = true; lock.unlock()
        sock.close()
    }

    /// The screen as it is now: width, height and BGRX bytes.
    public func snapshot() -> (width: Int, height: Int, pixels: [UInt8]) {
        lock.lock(); defer { lock.unlock() }
        return (width, height, pixels)
    }

    private func run() {
        do {
            try handshake()
            while true { try message() }
        } catch {
            lock.lock(); let quiet = stopped; lock.unlock()
            handler(.closed(quiet || error is ByteReader.EOF ? nil : error))
        }
    }

    struct ProtocolError: Error, CustomStringConvertible {
        let description: String
    }

    func handshake() throws {
        let version = try reader.bytes(12)
        guard version.starts(with: Array("RFB ".utf8)) else {
            throw ProtocolError(description: "not a VNC server")
        }
        try sock.write("RFB 003.008\n")
        let n = Int(try reader.u8())
        if n == 0 {
            let len = Int(try reader.u32())
            let why = String(decoding: try reader.bytes(len), as: UTF8.self)
            throw ProtocolError(description: "VNC refused: \(why)")
        }
        let types = try reader.bytes(n)
        guard types.contains(1) else {
            throw ProtocolError(description: "the VNC server wants a password")
        }
        try sock.write([1])
        if try reader.u32() != 0 {
            throw ProtocolError(description: "VNC security handshake failed")
        }
        try sock.write([1]) // ClientInit: shared
        let w = Int(try reader.u16()), h = Int(try reader.u16())
        try reader.skip(16) // the server's pixel format: we set our own
        let len = Int(try reader.u32())
        name = String(decoding: try reader.bytes(len), as: UTF8.self)
        resize(w, h)

        try sock.write(Self.setPixelFormat())
        try sock.write(Self.setEncodings([0, -223])) // raw, DesktopSize
        try sock.write(Self.updateRequest(incremental: false, width: w, height: h))
    }

    func message() throws {
        let type = try reader.u8()
        switch type {
        case 0: try framebufferUpdate()
        case 1: // SetColourMapEntries: not for true colour, but skip it
            try reader.skip(3)
            let n = Int(try reader.u16())
            try reader.skip(n * 6)
        case 2: break // Bell
        case 3: // ServerCutText
            try reader.skip(3)
            try reader.skip(Int(try reader.u32()))
        default:
            throw ProtocolError(description: "unknown VNC message \(type)")
        }
    }

    private func framebufferUpdate() throws {
        try reader.skip(1)
        let rects = Int(try reader.u16())
        var changed = false
        for _ in 0..<rects {
            let x = Int(try reader.u16()), y = Int(try reader.u16())
            let w = Int(try reader.u16()), h = Int(try reader.u16())
            let enc = Int32(bitPattern: try reader.u32())
            switch enc {
            case 0:
                try raw(x, y, w, h)
                changed = true
            case -223:
                resize(w, h)
                handler(.resized(width: w, height: h))
                changed = true
            default:
                throw ProtocolError(description: "unexpected VNC encoding \(enc)")
            }
        }
        if changed { handler(.updated) }
        lock.lock(); let w = width, h = height; lock.unlock()
        try sock.write(Self.updateRequest(incremental: true, width: w, height: h))
    }

    private func raw(_ x: Int, _ y: Int, _ w: Int, _ h: Int) throws {
        let rowBytes = w * 4
        var row = [UInt8](repeating: 0, count: rowBytes)
        for r in 0..<h {
            var off = 0
            try reader.bytes(rowBytes) { piece in
                row.withUnsafeMutableBufferPointer { dst in
                    piece.withUnsafeBufferPointer { src in
                        (dst.baseAddress! + off).update(from: src.baseAddress!, count: src.count)
                    }
                }
                off += piece.count
            }
            lock.lock()
            let yy = y + r
            if yy < height && x < width {
                let n = min(w, width - x) * 4
                let dst = (yy * width + x) * 4
                pixels.withUnsafeMutableBufferPointer { p in
                    row.withUnsafeBufferPointer { s in
                        (p.baseAddress! + dst).update(from: s.baseAddress!, count: n)
                    }
                }
            }
            lock.unlock()
        }
    }

    private func resize(_ w: Int, _ h: Int) {
        lock.lock()
        width = w; height = h
        pixels = [UInt8](repeating: 0, count: w * h * 4)
        lock.unlock()
    }

    // MARK: - client messages

    static func setPixelFormat() -> [UInt8] {
        // 32 bpp, depth 24, little-endian, true colour, 8 bits a channel,
        // red at bit 16, green at 8, blue at 0.
        [0, 0, 0, 0,
         32, 24, 0, 1,
         0, 255, 0, 255, 0, 255,
         16, 8, 0,
         0, 0, 0]
    }

    static func setEncodings(_ encs: [Int32]) -> [UInt8] {
        var m: [UInt8] = [2, 0, UInt8(encs.count >> 8), UInt8(encs.count & 0xff)]
        for e in encs {
            let u = UInt32(bitPattern: e)
            m += [UInt8(u >> 24), UInt8(u >> 16 & 0xff), UInt8(u >> 8 & 0xff), UInt8(u & 0xff)]
        }
        return m
    }

    static func updateRequest(incremental: Bool, width: Int, height: Int) -> [UInt8] {
        [3, incremental ? 1 : 0, 0, 0, 0, 0,
         UInt8(width >> 8), UInt8(width & 0xff), UInt8(height >> 8), UInt8(height & 0xff)]
    }
}
