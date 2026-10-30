// SPDX-License-Identifier: GPL-2.0-or-later
//
// A blocking stream socket, for QEMU's unix sockets (QMP, VNC, the
// serial console). Each protocol reads on a thread of its own.

import Foundation

public struct SocketError: Error, CustomStringConvertible {
    public let description: String
    init(_ what: String, _ err: Int32 = errno) {
        description = "\(what): \(String(cString: strerror(err)))"
    }
    init(message: String) { description = message }
}

public final class UnixSocket: @unchecked Sendable {
    public let fd: Int32
    private let lock = NSLock()
    private var closed = false

    /// Takes over an open stream socket (one end of a socketpair, in tests).
    public init(fd: Int32) {
        self.fd = fd
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Connects to the socket at path, retrying until timeout while QEMU
    /// starts up and creates it.
    public static func connect(path: String, timeout: TimeInterval = 10) throws -> UnixSocket {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < cap else {
            throw SocketError(message: "socket path too long: \(path)")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { p in
            p.copyBytes(from: bytes)
            p[bytes.count] = 0
        }
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            if fd < 0 { throw SocketError("socket") }
            let r = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if r == 0 { return UnixSocket(fd: fd) }
            let err = errno
            Darwin.close(fd)
            if Date() > deadline { throw SocketError("connect \(path)", err) }
            usleep(50_000)
        }
    }

    /// Up to max bytes; empty at end of stream or on error.
    public func read(max: Int = 65536) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: max)
        while true {
            let n = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, max) }
            if n > 0 { return Array(buf[0..<n]) }
            if n < 0 && errno == EINTR { continue }
            return []
        }
    }

    public func write(_ data: [UInt8]) throws {
        var off = 0
        while off < data.count {
            let n = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + off, data.count - off) }
            if n < 0 {
                if errno == EINTR { continue }
                throw SocketError("write")
            }
            off += n
        }
    }

    public func write(_ s: String) throws { try write(Array(s.utf8)) }

    /// Wakes a reader blocked in read() and frees the descriptor once.
    public func close() {
        lock.lock(); defer { lock.unlock() }
        if closed { return }
        closed = true
        shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
    }

    deinit { close() }

    /// A connected pair, for tests.
    public static func pair() -> (UnixSocket, UnixSocket) {
        var fds: [Int32] = [0, 0]
        socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
        return (UnixSocket(fd: fds[0]), UnixSocket(fd: fds[1]))
    }
}

/// Exact-length reads over a socket, buffered.
public final class ByteReader {
    private let sock: UnixSocket
    private var buf: [UInt8] = []
    private var pos = 0

    public init(_ sock: UnixSocket) { self.sock = sock }

    public struct EOF: Error {}

    public func bytes(_ n: Int) throws -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(n)
        try bytes(n) { out.append(contentsOf: $0) }
        return out
    }

    /// n bytes, handed over in the pieces they arrive in.
    public func bytes(_ n: Int, _ sink: (ArraySlice<UInt8>) -> Void) throws {
        var left = n
        while left > 0 {
            if pos == buf.count {
                buf = sock.read(max: max(65536, min(left, 1 << 20)))
                pos = 0
                if buf.isEmpty { throw EOF() }
            }
            let take = min(left, buf.count - pos)
            sink(buf[pos..<pos + take])
            pos += take
            left -= take
        }
    }

    public func u8() throws -> UInt8 { try bytes(1)[0] }
    public func u16() throws -> UInt16 {
        let b = try bytes(2); return UInt16(b[0]) << 8 | UInt16(b[1])
    }
    public func u32() throws -> UInt32 {
        let b = try bytes(4)
        return UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
    }
    public func skip(_ n: Int) throws { try bytes(n) { _ in } }

    /// A line ending in \n (the \n and a \r before it dropped).
    public func line() throws -> [UInt8] {
        var out = [UInt8]()
        while true {
            if pos == buf.count {
                buf = sock.read()
                pos = 0
                if buf.isEmpty { throw EOF() }
            }
            if let nl = buf[pos...].firstIndex(of: 10) {
                out.append(contentsOf: buf[pos..<nl])
                pos = nl + 1
                if out.last == 13 { out.removeLast() }
                return out
            }
            out.append(contentsOf: buf[pos...])
            pos = buf.count
        }
    }
}
