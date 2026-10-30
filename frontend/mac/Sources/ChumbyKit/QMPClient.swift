// SPDX-License-Identifier: GPL-2.0-or-later
//
// A QMP connection: commands from any thread, each tagged with an id so
// its reply finds it; events to a handler. QEMU writes one JSON object a
// line.

import Foundation

public struct QMPError: Error, CustomStringConvertible {
    public let description: String
    public init(_ d: String) { description = d }
    public static let closed = QMPError("the machine has quit")
}

public final class QMPClient: @unchecked Sendable {
    public typealias Reply = Result<Any?, QMPError>

    private let sock: UnixSocket
    private let reader: ByteReader
    private let lock = NSLock()
    private var nextID = 1
    private var pending: [Int: (Reply) -> Void] = [:]
    private var closed = false
    /// Events, as (name, data), on the reader's thread.
    public var onEvent: ((String, [String: Any]) -> Void)?
    /// The connection ended, on the reader's thread.
    public var onClose: (() -> Void)?

    public init(socket: UnixSocket) {
        sock = socket
        reader = ByteReader(socket)
    }

    public var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }

    /// Reads the greeting, leaves capabilities negotiation mode, and starts
    /// reading replies and events. Blocks: call it off the main thread.
    public func start() throws {
        let greeting = try reader.line()
        guard let g = try? JSONSerialization.jsonObject(with: Data(greeting)) as? [String: Any],
              g["QMP"] != nil else {
            throw QMPError("not a QMP server")
        }
        try sock.write(#"{"execute":"qmp_capabilities"}"# + "\n")
        while true {
            let line = try reader.line()
            guard let m = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            if m["return"] != nil { break }
            if let e = m["error"] as? [String: Any] {
                throw QMPError(e["desc"] as? String ?? "qmp_capabilities failed")
            }
        }
        let t = Thread { [self] in readLoop() }
        t.name = "qmp"
        t.start()
    }

    /// Sends a command; completion (if any) runs on the reader's thread.
    public func send(_ name: String, _ args: [String: Any]? = nil,
                     completion: ((Reply) -> Void)? = nil) {
        lock.lock()
        if closed {
            lock.unlock()
            completion?(.failure(.closed))
            return
        }
        let id = nextID
        nextID += 1
        pending[id] = completion ?? { _ in }
        var msg: [String: Any] = ["execute": name, "id": id]
        if let args { msg["arguments"] = args }
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: msg)
        } catch {
            pending[id] = nil
            lock.unlock()
            completion?(.failure(QMPError("bad arguments for \(name)")))
            return
        }
        // Written under the lock, so commands go out whole and in order.
        let ok = (try? sock.write(Array(data) + [10])) != nil
        lock.unlock()
        if !ok { finish(id, .failure(.closed)) }
    }

    /// Sends a command and waits for its reply. Not on the reader's thread.
    public func call(_ name: String, _ args: [String: Any]? = nil,
                     timeout: TimeInterval = 30) throws -> Any? {
        let done = DispatchSemaphore(value: 0)
        var result: Reply = .failure(QMPError("\(name) timed out"))
        send(name, args) { r in result = r; done.signal() }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            throw QMPError("\(name) timed out")
        }
        return try result.get()
    }

    public func close() { sock.close() }

    private func finish(_ id: Int, _ r: Reply) {
        lock.lock()
        let c = pending.removeValue(forKey: id)
        lock.unlock()
        c?(r)
    }

    private func readLoop() {
        while let line = try? reader.line() {
            guard let m = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            if let ev = m["event"] as? String {
                onEvent?(ev, m["data"] as? [String: Any] ?? [:])
            } else if let id = m["id"] as? Int {
                if let e = m["error"] as? [String: Any] {
                    finish(id, .failure(QMPError(e["desc"] as? String ?? "\(e)")))
                } else {
                    let r = m["return"]
                    finish(id, .success(r is NSNull ? nil : r))
                }
            }
        }
        lock.lock()
        closed = true
        let waiting = pending
        pending = [:]
        lock.unlock()
        for (_, c) in waiting { c(.failure(.closed)) }
        onClose?()
    }

    // MARK: - the machine's commands

    public func qomSet(_ prop: String, _ value: Any, path: String = "/machine",
                       completion: ((Reply) -> Void)? = nil) {
        send("qom-set", ["path": path, "property": prop, "value": value], completion: completion)
    }

    public func qomGet(_ prop: String, path: String = "/machine") throws -> Any? {
        try call("qom-get", ["path": path, "property": prop])
    }

    /// input-send-event's events for the pen at Chumby pixel (x, y) of a
    /// width x height screen, and whether it is pressed (nil: unchanged).
    public static func penEvents(x: Double, y: Double, width: Int, height: Int,
                                 down: Bool?) -> [[String: Any]] {
        func axis(_ v: Double, _ n: Int) -> Int {
            let f = v / Double(max(1, n))
            return Int((min(max(f, 0), 1) * 32767).rounded())
        }
        var ev: [[String: Any]] = [
            ["type": "abs", "data": ["axis": "x", "value": axis(x, width)]],
            ["type": "abs", "data": ["axis": "y", "value": axis(y, height)]],
        ]
        if let down {
            ev.append(["type": "btn", "data": ["down": down, "button": "left"]])
        }
        return ev
    }

    public static func keyEvent(qcode: String, down: Bool) -> [String: Any] {
        ["type": "key", "data": ["down": down, "key": ["type": "qcode", "data": qcode]]]
    }

    public func sendInput(_ events: [[String: Any]]) {
        send("input-send-event", ["events": events])
    }
}
