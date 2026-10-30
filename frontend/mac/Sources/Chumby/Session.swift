// SPDX-License-Identifier: GPL-2.0-or-later
//
// One running Chumby: the QEMU process and its three sockets. QMP drives
// the machine (the pen, keys, the board's properties, snapshots), VNC
// carries the screen, and the serial socket is the console.

import AppKit
import ChumbyKit
import Combine

@MainActor
final class Session: ObservableObject {
    enum Phase: Equatable {
        case starting
        case running
        case ended(String?)
    }

    let options: LaunchOptions
    @Published private(set) var phase = Phase.starting
    /// Not paused.
    @Published private(set) var running = true
    @Published var tilt = Tilt.upright
    @Published private(set) var accel = [0, 0, 1000]
    @Published private(set) var following = false
    @Published private(set) var headphones = false
    @Published private(set) var backlight: Double?
    @Published private(set) var lcdOn: Bool?
    @Published private(set) var speakerMuted: Bool?
    @Published private(set) var buttonDown = false
    @Published private(set) var message: String?
    @Published private(set) var screenSize = CGSize(width: 320, height: 240)
    /// Bumped when the console's terminal changes (at most 30 times a second).
    @Published private(set) var consoleVersion = 0
    /// The kernel's version, once its banner is on the console.
    @Published private(set) var linuxVersion: String?
    private var versionWatch = LinuxVersionWatch()

    private(set) var props: Set<String> = []
    private(set) var features = QemuFeatures()
    private(set) var audio = "none"
    private(set) var ttyPath: String?
    private(set) var snapshotName = "chumby"
    private(set) var otherSnapshot = "chumby-fast"
    private(set) var canSaveState = false
    let terminal = Terminal()
    let motionAvailable = MotionSensor.available()

    /// The newest frame, for the screen view.
    var onFrame: ((CGImage) -> Void)?
    private(set) var image: CGImage?

    private var process: Process?
    private var qmp: QMPClient?
    private var rfb: RFBClient?
    private var console: Console?
    private var dir: String?
    private var motion: MotionSensor?
    private var motionTimer: Timer?
    private var messageTimer: Timer?
    private let flags = Flags()
    private var stderrTail = ""
    private var quitting = false

    init(options: LaunchOptions) {
        self.options = options
    }

    func has(_ names: String...) -> Bool { names.allSatisfy(props.contains) }

    /// The machine takes F12 (or its button-key) for the top button itself.
    var machineHasButtonKey: Bool { props.contains("button-key") }
    /// It plugs in a USB keyboard on the first key.
    var machineHasKeyboard: Bool { props.contains("usb-keyboard") }

    // MARK: - starting

    func start() {
        let options = self.options
        let flags = self.flags
        let me = WeakBox(self)
        Task.detached {
            do {
                let parts = try Self.launch(options: options, flags: flags) { line in
                    Task { @MainActor in me.value?.appendStderr(line) }
                }
                if let s = me.value {
                    await s.started(parts)
                } else {
                    parts.process.terminate()
                }
            } catch {
                await me.value?.failed(error)
            }
        }
    }

    struct Parts: @unchecked Sendable {
        var process: Process
        var qmp: QMPClient
        var rfb: RFBClient?
        var console: Console?
        var dir: String
        var features: QemuFeatures
        var props: Set<String>
        var audio: String
        var fast: Bool
        var stateful: Bool
        var status: [String: Any]
        var outputs: [String: Any]
        var accel: [Int]
    }

    /// Finds QEMU, starts it and connects to it. Off the main thread.
    nonisolated static func launch(options o: LaunchOptions, flags: Flags,
                                   stderr: @escaping @Sendable (String) -> Void) throws -> Parts {
        guard let qemu = QemuLocator.find(given: o.qemu) else {
            throw LaunchError("No qemu-system-arm with the chumby-classic machine was found. Choose one in the start window, or pass --qemu.")
        }
        guard let kernel = o.kernelPath, FileManager.default.fileExists(atPath: kernel) else {
            throw LaunchError("There is no kernel at \(o.kernelPath ?? "(none)").")
        }
        let features = QemuFeatures.probe(qemu: qemu)
        guard !features.machineOptions.isEmpty else {
            throw LaunchError("\(qemu) has no chumby-classic machine.")
        }
        var opts = o
        let dir = try makeSocketDir()
        var cmd = QemuCommand(qemu: qemu, options: opts, features: features, dir: dir)
        var stateful = false
        if let nand = o.nandPath, let state = o.state {
            let (overlay, saved) = try StateDir.prepare(qemu: qemu, nand: nand, state: state)
            cmd.overlay = overlay
            stateful = true
            if let saved {
                if saved != opts.fast {
                    FileHandle.standardError.write(Data(("Chumby: resuming the saved state " +
                        (saved ? "with" : "without") + " --fast, as it was saved\n").utf8))
                    opts.fast = saved
                    cmd.options = opts
                }
                cmd.resume = true
            }
        }
        let args = try cmd.arguments()
        FileHandle.standardError.write(Data(("Chumby: " + ([qemu] + args).joined(separator: " ") + "\n").utf8))

        let p = Process()
        p.executableURL = URL(fileURLWithPath: qemu)
        p.arguments = args
        // QEMU's messages go on to ours, and the last of them to the window
        // if it fails to start.
        let pipe = Pipe()
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            FileHandle.standardError.write(d)
            stderr(String(decoding: d, as: UTF8.self))
        }
        try p.run()
        flags.setPID(p.processIdentifier)

        func fail(_ e: Error) -> Error {
            if p.isRunning { p.terminate() }
            try? FileManager.default.removeItem(atPath: dir)
            return e
        }
        let qmp: QMPClient
        do {
            let s = try UnixSocket.connect(path: cmd.qmpPath, timeout: 20)
            qmp = QMPClient(socket: s)
            try qmp.start()
        } catch {
            p.waitUntilExit()
            throw fail(LaunchError("QEMU didn't start (exit status \(p.terminationStatus))."))
        }
        let list = (try? qmp.call("qom-list", ["path": "/machine"])) as? [[String: Any]] ?? []
        let props = Set(list.compactMap { $0["name"] as? String })

        var rfb: RFBClient?
        if let s = try? UnixSocket.connect(path: cmd.vncPath, timeout: 5) {
            rfb = RFBClient(socket: s) { ev in flags.rfbEvent(ev) }
        }
        var console: Console?
        if let s = try? UnixSocket.connect(path: cmd.consolePath, timeout: 5) {
            console = try? Console(socket: s)
        }
        let status = (try? qmp.call("query-status")) as? [String: Any] ?? [:]
        let outputs = (try? qmp.call("query-chumby-state")) as? [String: Any] ?? [:]
        var accel = [0, 0, 1000]
        if ["accel-x", "accel-y", "accel-z"].allSatisfy(props.contains) {
            accel = ["accel-x", "accel-y", "accel-z"].map { ((try? qmp.qomGet($0)) as? Int) ?? 0 }
        }
        return Parts(process: p, qmp: qmp, rfb: rfb, console: console, dir: dir,
                     features: features, props: props, audio: cmd.audio, fast: opts.fast,
                     stateful: stateful, status: status, outputs: outputs, accel: accel)
    }

    private func started(_ parts: Parts) {
        process = parts.process
        qmp = parts.qmp
        rfb = parts.rfb
        console = parts.console
        dir = parts.dir
        features = parts.features
        props = parts.props
        audio = parts.audio
        snapshotName = Snapshot.name(fast: parts.fast)
        otherSnapshot = Snapshot.name(fast: !parts.fast)
        canSaveState = parts.stateful
        ttyPath = parts.console?.ttyPath
        running = parts.status["running"] as? Bool ?? true
        accel = parts.accel
        tilt = Tilt(gravity: parts.accel)
        show(outputs: parts.outputs)

        flags.onFrame = { [weak self] in self?.frame() }
        flags.onResize = { [weak self] w, h in self?.screenSize = CGSize(width: w, height: h) }
        parts.qmp.onEvent = { [weak self] name, _ in
            Task { @MainActor in self?.event(name) }
        }
        if let c = parts.console {
            let term = terminal
            let f = flags
            c.onOutput = { [weak self] bytes in
                DispatchQueue.main.async {
                    term.feed(bytes)
                    f.consoleChanged()
                    if let v = self?.versionWatch.feed(bytes) { self?.linuxVersion = v }
                }
            }
            flags.onConsole = { [weak self] in self?.consoleVersion &+= 1 }
            c.start()
        }
        parts.rfb?.start()
        parts.process.terminationHandler = { [weak self] p in
            let status = p.terminationStatus
            Task { @MainActor in self?.exited(status) }
        }
        if !parts.process.isRunning { exited(parts.process.terminationStatus); return }
        phase = .running
        if let tty = ttyPath {
            FileHandle.standardError.write(Data("Chumby: the console is \(tty)\n".utf8))
        }
    }

    private func failed(_ error: Error) {
        let tail = stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
        phase = .ended("\(error)" + (tail.isEmpty ? "" : "\n\n" + tail))
    }

    private func appendStderr(_ s: String) {
        stderrTail = String((stderrTail + s).suffix(2000))
    }

    private func exited(_ status: Int32) {
        if case .ended = phase { return }
        teardown()
        let tail = stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
        if quitting || status == 0 {
            phase = .ended(nil)
        } else {
            phase = .ended("QEMU exited with status \(status)." + (tail.isEmpty ? "" : "\n\n" + tail))
        }
    }

    private func teardown() {
        setFollow(false)
        rfb?.stop()
        console?.close()
        qmp?.close()
        if let dir { try? FileManager.default.removeItem(atPath: dir) }
        dir = nil
    }

    // MARK: - quitting

    /// Asks QEMU to quit, then makes sure it has; done runs on the main
    /// thread once it is gone.
    func quit(_ done: @escaping () -> Void) {
        quitting = true
        guard let p = process, p.isRunning else {
            if case .ended = phase {} else { teardown(); phase = .ended(nil) }
            flags.killIfRunning()
            done()
            return
        }
        qmp?.send("quit")
        DispatchQueue.global().async {
            let deadline = Date().addingTimeInterval(3)
            while p.isRunning && Date() < deadline { usleep(20_000) }
            if p.isRunning { p.terminate() }
            let kill = Date().addingTimeInterval(2)
            while p.isRunning && Date() < kill { usleep(20_000) }
            if p.isRunning { Darwin.kill(p.processIdentifier, SIGKILL) }
            // The run loop's, not the main queue's: the app may be waiting
            // for this in a nested run loop (terminateLater) inside a block.
            RunLoop.main.perform(inModes: [.common, .modalPanel]) {
                MainActor.assumeIsolated {
                    self.teardown()
                    done()
                }
            }
        }
    }

    /// Last resort at exit: no QEMU outlives the app.
    nonisolated func killNow() { flags.killIfRunning() }

    // MARK: - the screen

    private func frame() {
        guard let rfb else { return }
        let s = rfb.snapshot()
        guard s.width > 0, s.height > 0,
              let provider = CGDataProvider(data: Data(s.pixels) as CFData),
              let img = CGImage(width: s.width, height: s.height, bitsPerComponent: 8, bitsPerPixel: 32,
                                bytesPerRow: s.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue |
                                                         CGImageAlphaInfo.noneSkipFirst.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: false,
                                intent: .defaultIntent)
        else { return }
        image = img
        onFrame?(img)
    }

    /// The pen at a point of the screen, in Chumby pixels from its top left.
    func pen(x: Double, y: Double, down: Bool?) {
        qmp?.sendInput(QMPClient.penEvents(x: x, y: y, width: Int(screenSize.width),
                                           height: Int(screenSize.height), down: down))
    }

    func key(_ qcode: String, down: Bool) {
        if qcode == "f12" && !machineHasButtonKey && has("button") {
            setButton(down)
            return
        }
        qmp?.sendInput([QMPClient.keyEvent(qcode: qcode, down: down)])
    }

    // MARK: - the board

    func setButton(_ down: Bool) {
        buttonDown = down
        qmp?.qomSet("button", down)
    }

    func tapButton() {
        setButton(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.setButton(false) }
    }

    func setHeadphones(_ on: Bool) {
        headphones = on
        qmp?.qomSet("headphones", on) { [weak self] r in
            if case .failure(let e) = r { Task { @MainActor in self?.say(e.description) } }
        }
    }

    func setTilt(_ t: Tilt) {
        tilt = t
        if !following { writeAccel(t.gravity) }
    }

    private func writeAccel(_ g: [Int]) {
        accel = g
        guard has("accel-x", "accel-y", "accel-z") else { return }
        for (p, v) in zip(["accel-x", "accel-y", "accel-z"], g) { qmp?.qomSet(p, v) }
    }

    func shake() {
        let base = following ? accel : tilt.gravity
        for (i, (dx, dy)) in Tilt.shakeSteps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06 * Double(i)) { [weak self] in
                self?.writeAccel([base[0] + dx, base[1] + dy, base[2]])
            }
        }
    }

    func setFollow(_ on: Bool) {
        if on && motion == nil {
            let latest = flags
            let m = MotionSensor { x, y, z in latest.setMotion(Tilt.fromMac(x: x, y: y, z: z)) }
            guard m.ok else {
                m.stop()
                say("This Mac's motion sensor didn't start")
                return
            }
            motion = m
            following = true
            motionTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let g = self.flags.takeMotion() else { return }
                    self.writeAccel(g)
                }
            }
        } else if !on, let m = motion {
            m.stop()
            motion = nil
            motionTimer?.invalidate()
            motionTimer = nil
            following = false
            writeAccel(tilt.gravity)
        }
    }

    private func event(_ name: String) {
        switch name {
        case "STOP": running = false
        case "RESUME": running = true
        default:
            if name.hasPrefix("CHUMBY_") { refreshOutputs() }
        }
    }

    private func refreshOutputs() {
        qmp?.send("query-chumby-state") { [weak self] r in
            guard case .success(let v) = r, let o = v as? [String: Any] else { return }
            let box = UncheckedBox(o)
            Task { @MainActor in self?.show(outputs: box.value) }
        }
    }

    private func show(outputs o: [String: Any]) {
        if let v = o["backlight"] as? Int { backlight = Double(v) / 65535 }
        if let v = o["lcd-on"] as? Bool { lcdOn = v }
        if let v = o["speaker-mute"] as? Bool { speakerMuted = v }
        if let v = o["headphones"] as? Bool { headphones = v }
        if let v = o["button"] as? Bool { buttonDown = v }
    }

    // MARK: - the machine

    func togglePause() {
        let cmd = running ? "stop" : "cont"
        running.toggle() // the STOP or RESUME event confirms it
        qmp?.send(cmd)
    }

    func reset() {
        qmp?.send("system_reset")
        say("Reset")
    }

    func saveState() {
        say("Saving…", sticky: true)
        hmp("savevm " + snapshotName) { [weak self] out in
            guard let self else { return }
            // One saved state: the other clock's is stale now.
            self.hmp("delvm " + self.otherSnapshot) { _ in }
            self.say(out.isEmpty ? "Saved the state" : out)
        }
    }

    func loadState() {
        hmp("loadvm " + snapshotName) { [weak self] out in
            self?.say(out.isEmpty ? "Restored the saved state" : out)
        }
    }

    private func hmp(_ line: String, _ done: @escaping @MainActor (String) -> Void) {
        qmp?.send("human-monitor-command", ["command-line": line]) { r in
            let out: String
            switch r {
            case .success(let v): out = (v as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            case .failure(let e): out = e.description
            }
            Task { @MainActor in done(out) }
        }
    }

    func screenshot(to url: URL) {
        qmp?.send("screendump", ["filename": url.path, "format": "png"]) { [weak self] r in
            let msg: String
            if case .failure(let e) = r { msg = e.description } else { msg = "Saved \(url.lastPathComponent)" }
            Task { @MainActor in self?.say(msg) }
        }
    }

    func copyScreen() {
        guard let image else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        let pb = NSPasteboard.general
        pb.clearContents()
        if let png = rep.representation(using: .png, properties: [:]) {
            pb.setData(png, forType: .png)
        }
        pb.writeObjects([NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))])
        say("Copied the screen")
    }

    // MARK: - the console

    func sendToConsole(_ bytes: [UInt8]) { console?.send(bytes) }

    func say(_ s: String, sticky: Bool = false) {
        message = s
        messageTimer?.invalidate()
        if !sticky {
            messageTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.message = nil }
            }
        }
    }
}

final class WeakBox<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
    init(_ v: T) { value = v }
}

struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ v: T) { value = v }
}

/// What the client threads hand to the main thread, coalesced: a frame
/// waiting to be drawn, the console's changes, the latest motion reading.
final class Flags: @unchecked Sendable {
    private let lock = NSLock()
    private var framePending = false
    private var consolePending = false
    private var motion: [Int]?
    private var pid: pid_t = 0
    @MainActor var onFrame: (() -> Void)?
    @MainActor var onResize: ((Int, Int) -> Void)?
    @MainActor var onConsole: (() -> Void)?

    func setPID(_ p: pid_t) { lock.lock(); pid = p; lock.unlock() }

    func killIfRunning() {
        lock.lock(); let p = pid; lock.unlock()
        if p > 0 && Darwin.kill(p, 0) == 0 { Darwin.kill(p, SIGKILL) }
    }

    func rfbEvent(_ ev: RFBClient.Event) {
        switch ev {
        case .updated:
            lock.lock()
            let schedule = !framePending
            framePending = true
            lock.unlock()
            if schedule {
                DispatchQueue.main.async {
                    self.lock.lock(); self.framePending = false; self.lock.unlock()
                    MainActor.assumeIsolated { self.onFrame?() }
                }
            }
        case .resized(let w, let h):
            DispatchQueue.main.async { MainActor.assumeIsolated { self.onResize?(w, h) } }
        case .closed:
            break
        }
    }

    /// On the main thread, after the terminal took new output.
    @MainActor func consoleChanged() {
        if consolePending { return }
        consolePending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 30) {
            MainActor.assumeIsolated {
                self.consolePending = false
                self.onConsole?()
            }
        }
    }

    func setMotion(_ g: [Int]) { lock.lock(); motion = g; lock.unlock() }
    func takeMotion() -> [Int]? {
        lock.lock(); defer { lock.unlock() }
        let m = motion
        motion = nil
        return m
    }
}

/// Where qemu-system-arm is: given, chosen before (the start window), in
/// $CHUMBY_QEMU, beside a checkout's app bundle, or on $PATH.
enum QemuLocator {
    static let defaultsKey = "QEMUPath"

    static func find(given: String?) -> String? {
        let fm = FileManager.default
        var candidates: [String] = []
        if let given { return fm.isExecutableFile(atPath: given) ? given : nil }
        if let d = UserDefaults.standard.string(forKey: defaultsKey) { candidates.append(d) }
        if let e = ProcessInfo.processInfo.environment["CHUMBY_QEMU"] { candidates.append(e) }
        // frontend/mac/build/Chumby.app in a checkout: the checkout's QEMU.
        let repo = Bundle.main.bundleURL.deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        candidates += [repo.appendingPathComponent("qemu-system-arm").path,
                       repo.appendingPathComponent("build/obj/qemu-system-arm").path]
        for c in candidates where fm.isExecutableFile(atPath: c) { return c }
        return findInPath("qemu-system-arm")
    }
}
