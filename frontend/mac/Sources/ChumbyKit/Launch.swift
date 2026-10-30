// SPDX-License-Identifier: GPL-2.0-or-later
//
// What to run and how: chumby-emu's options, and the QEMU command line
// they make. The emulated Chumby never has a network: QEMU always runs
// with -nic none, and network options among the extra arguments are
// refused.

import Foundation

public struct LaunchError: Error, CustomStringConvertible {
    public let description: String
    public init(_ d: String) { description = d }
}

public struct LaunchOptions: Codable, Hashable, Sendable {
    /// A directory with zImage and nand.img.
    public var images: String?
    public var kernel: String?
    public var nand: String?
    public var qemu: String?
    /// coreaudio, wav:FILE or none; nil: coreaudio when QEMU has it.
    public var audio: String?
    public var write = false
    /// A directory for the NAND's qcow2 overlay and the saved state.
    public var state: String?
    public var fast = false
    /// Points per Chumby pixel; nil: a real Chumby's screen size.
    public var scale: Double?
    /// Passed to QEMU as they are.
    public var extra: [String] = []

    public init() {}

    public static let usage = """
        Chumby IMAGES                     a directory with zImage and nand.img
        Chumby --kernel zImage [--nand nand.img]

        --qemu PATH     qemu-system-arm with the chumby-classic machine
        --audio NAME    coreaudio, wav:FILE or none (default: coreaudio)
        --write         write the NAND image (default: snapshot=on)
        --state DIR     keep flash writes and the saved state in DIR
        --fast          -icount shift=auto,sleep=off: quick boots, for tests
        --scale N       points per Chumby pixel (default: a real Chumby's size)
        -- ARGS         passed to QEMU as they are
      """

    /// chumby-emu's options (--display and --no-panel are chumby-emu's
    /// own: it runs Python's panel for those).
    public static func parse(_ args: [String]) throws -> LaunchOptions {
        var o = LaunchOptions()
        // --opt=value as --opt value, up to "--".
        var argv: [String] = []
        for (n, a) in args.enumerated() {
            if a == "--" { argv += args[n...]; break }
            if a.hasPrefix("--"), let eq = a.firstIndex(of: "=") {
                argv += [String(a[..<eq]), String(a[a.index(after: eq)...])]
            } else {
                argv.append(a)
            }
        }
        var i = 0
        func value(_ name: String) throws -> String {
            i += 1
            guard i < argv.count else { throw LaunchError("\(name) needs a value") }
            return argv[i]
        }
        while i < argv.count {
            let a = argv[i]
            switch a {
            case "--": o.extra = Array(argv[(i + 1)...]); i = argv.count; continue
            case "--kernel": o.kernel = try value(a)
            case "--nand": o.nand = try value(a)
            case "--qemu": o.qemu = try value(a)
            case "--audio": o.audio = try value(a)
            case "--state": o.state = try value(a)
            case "--write": o.write = true
            case "--fast": o.fast = true
            case "--scale":
                guard let s = Double(try value(a)), s > 0 else { throw LaunchError("--scale needs a number") }
                o.scale = s
            case "-h", "--help": throw LaunchError(usage)
            default:
                // AppKit's own arguments (-NSDocumentRevisionsDebugMode YES,
                // -psn_0_...) pass through.
                if a.hasPrefix("-psn_") { break }
                if a.hasPrefix("-NS") || a.hasPrefix("-Apple") { i += 1; break }
                if a.hasPrefix("-") { throw LaunchError("unknown option \(a)\n\n\(usage)") }
                guard o.images == nil else { throw LaunchError("one images directory only") }
                o.images = a
            }
            i += 1
        }
        return o
    }

    public var isEmpty: Bool { images == nil && kernel == nil }

    public var kernelPath: String? {
        kernel ?? images.map { ($0 as NSString).appendingPathComponent("zImage") }
    }

    /// The NAND image: given, or the images directory's, if it has one.
    public var nandPath: String? {
        if let nand { return nand }
        guard let images else { return nil }
        let p = (images as NSString).appendingPathComponent("nand.img")
        return FileManager.default.fileExists(atPath: p) ? p : nil
    }

    /// A short name for recents and the window title.
    public var displayName: String {
        if let images { return (images as NSString).lastPathComponent }
        if let kernel { return (kernel as NSString).lastPathComponent }
        return "Chumby"
    }
}

/// The saved state's name says which clock it was saved with: a state saved
/// with -icount can't be loaded without it, nor the other way round.
public enum Snapshot {
    public static func name(fast: Bool) -> String { fast ? "chumby-fast" : "chumby" }
}

/// What a qemu-system-arm can do, from its help output.
public struct QemuFeatures: Sendable {
    public var machineOptions: Set<String> = []
    public var audioDrivers: Set<String> = []
    public var displays: Set<String> = []
    public init() {}

    public static func probe(qemu: String) -> QemuFeatures {
        var f = QemuFeatures()
        f.machineOptions = Set(run(qemu, ["-M", "chumby-classic,help"]).split(separator: "\n").compactMap { l in
            let t = l.trimmingCharacters(in: .whitespaces)
            guard let eq = t.firstIndex(of: "=") else { return nil }
            return String(t[..<eq])
        })
        f.audioDrivers = words(run(qemu, ["-audiodev", "help"]))
        f.displays = words(run(qemu, ["-display", "help"]))
        return f
    }

    static func words(_ s: String) -> Set<String> {
        Set(s.replacingOccurrences(of: ",", with: " ").split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init))
    }
}

func run(_ exe: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return "" }
    let d = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: d, as: UTF8.self)
}

public struct QemuCommand {
    public var qemu: String
    public var options: LaunchOptions
    public var features: QemuFeatures
    /// The sockets' directory: short, as a unix socket path must be.
    public var dir: String
    /// A saved state in the state directory, and the clock it was saved
    /// with, from StateDir.prepare.
    public var overlay: String?
    public var resume: Bool = false

    public init(qemu: String, options: LaunchOptions, features: QemuFeatures, dir: String) {
        self.qemu = qemu
        self.options = options
        self.features = features
        self.dir = dir
    }

    public var qmpPath: String { (dir as NSString).appendingPathComponent("qmp") }
    public var vncPath: String { (dir as NSString).appendingPathComponent("vnc") }
    public var consolePath: String { (dir as NSString).appendingPathComponent("con") }

    /// The audio backend: asked for, else CoreAudio when QEMU has it.
    public var audio: String {
        if let a = options.audio { return a }
        return features.audioDrivers.contains("coreaudio") ? "coreaudio" : "none"
    }

    /// Options QEMU mustn't be given: a network, and other displays (the
    /// app draws the screen from VNC). More -qmp and -serial are fine.
    public static let refused = ["-netdev", "-nic", "-net", "-display", "-vnc", "-nographic"]

    public func arguments() throws -> [String] {
        let o = options
        // QEMU takes --opt as -opt.
        let given = Set(o.extra.map { $0.hasPrefix("--") ? String($0.dropFirst()) : $0 })
        for bad in Self.refused where given.contains(bad) {
            if ["-netdev", "-nic", "-net"].contains(bad) {
                throw LaunchError("\(bad) isn't allowed: the emulated Chumby has no network")
            }
            throw LaunchError("\(bad) isn't allowed: the app draws the screen itself")
        }
        guard let kernel = o.kernelPath else { throw LaunchError("no kernel: give an images directory or --kernel") }
        var machine = "chumby-classic"
        var args = ["-name", "Chumby", "-kernel", kernel,
                    "-qmp", "unix:\(qmpPath),server=on,wait=off",
                    "-serial", "unix:\(consolePath),server=on,wait=off",
                    "-monitor", "none", "-nic", "none",
                    "-display", "none", "-vnc", "unix:\(vncPath)"]
        if let overlay {
            args += ["-drive", "if=mtd,file=\(overlay),format=qcow2"]
            if resume { args += ["-loadvm", Snapshot.name(fast: o.fast)] }
        } else if let nand = o.nandPath {
            args += ["-drive", "if=mtd,file=\(nand),format=raw" + (o.write ? "" : ",snapshot=on")]
        }
        let audio = self.audio
        if audio != "none" {
            if audio.hasPrefix("wav:") {
                args += ["-audiodev", "wav,id=snd0,path=\(audio.dropFirst(4))"]
            } else {
                args += ["-audiodev", "\(audio),id=snd0"]
            }
            if features.machineOptions.contains("audiodev") { machine += ",audiodev=snd0" }
        }
        if o.fast { args += ["-icount", "shift=auto,sleep=off"] }
        return ["-M", machine] + args + o.extra
    }
}

/// The --state directory: a qcow2 overlay of the NAND image, made on first
/// use, and the saved state in it.
public enum StateDir {
    public static func qemuImg(beside qemu: String) -> String? {
        let p = ((qemu as NSString).deletingLastPathComponent as NSString).appendingPathComponent("qemu-img")
        if FileManager.default.isExecutableFile(atPath: p) { return p }
        return findInPath("qemu-img")
    }

    /// The overlay, and the clock of the saved state it holds (nil: none).
    public static func prepare(qemu: String, nand: String, state: String) throws -> (overlay: String, savedFast: Bool?) {
        guard let qimg = qemuImg(beside: qemu) else {
            throw LaunchError("a state folder needs qemu-img, from your QEMU")
        }
        try FileManager.default.createDirectory(atPath: state, withIntermediateDirectories: true)
        let overlay = (state as NSString).appendingPathComponent("nand.qcow2")
        if !FileManager.default.fileExists(atPath: overlay) {
            let base = URL(fileURLWithPath: nand).standardizedFileURL.path
            let p = Process()
            p.executableURL = URL(fileURLWithPath: qimg)
            p.arguments = ["create", "-q", "-f", "qcow2", "-b", base, "-F", "raw", overlay]
            try p.run()
            p.waitUntilExit()
            if p.terminationStatus != 0 { throw LaunchError("qemu-img couldn't make \(overlay)") }
        }
        let snaps = QemuFeatures.words(run(qimg, ["snapshot", "-l", "-U", overlay]))
        for fast in [false, true] where snaps.contains(Snapshot.name(fast: fast)) {
            return (overlay, fast)
        }
        return (overlay, nil)
    }
}

public func findInPath(_ name: String) -> String? {
    let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
    var dirs = path.split(separator: ":").map(String.init)
    dirs += ["/opt/homebrew/bin", "/usr/local/bin",
             (NSHomeDirectory() as NSString).appendingPathComponent(".nix-profile/bin"),
             "/run/current-system/sw/bin"]
    for d in dirs {
        let p = (d as NSString).appendingPathComponent(name)
        if FileManager.default.isExecutableFile(atPath: p) { return p }
    }
    return nil
}

/// A fresh private directory for the sockets, with a short path.
public func makeSocketDir() throws -> String {
    var base = NSTemporaryDirectory()
    if base.utf8.count > 60 { base = "/tmp/" }
    var template = Array((base as NSString).appendingPathComponent("chumby-XXXXXX").utf8CString)
    guard let p = template.withUnsafeMutableBufferPointer({ mkdtemp($0.baseAddress!) }) else {
        throw SocketError("mkdtemp")
    }
    return String(cString: p)
}
