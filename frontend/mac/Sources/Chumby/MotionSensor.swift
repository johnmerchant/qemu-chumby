// SPDX-License-Identifier: GPL-2.0-or-later
//
// The motion sensor of an Apple-silicon Mac laptop (frontend/mac_motion.py,
// in Swift). The accelerometer in the base of these Macs is a HID device
// on Apple's vendor usage page (0xFF00, usage 3), behind an
// AppleSPUHIDDriver service that streams reports once its reporting and
// power properties are set. Each 22-byte report carries X, Y and Z as
// little-endian int32 at offset 6, in 1/65536 g. None of this is
// documented by Apple; it needs no privileges, only IOKit.

import Foundation
import IOKit
import IOKit.hid

final class MotionSensor: @unchecked Sendable {
    typealias Callback = @Sendable (Double, Double, Double) -> Void

    private let callback: Callback
    private var running = true
    private let started = DispatchSemaphore(value: 0)
    private(set) var ok = false
    private var saved: [UInt64: [String: Int]] = [:]
    private var manager: IOHIDManager?
    private var buffers: [UnsafeMutablePointer<UInt8>] = []
    private let lock = NSLock()

    private static let props = ["SensorPropertyReportingState", "SensorPropertyPowerState", "ReportInterval"]

    static func available() -> Bool {
        let (m, devs) = devices()
        if let m { IOHIDManagerClose(m, 0) }
        return !devs.isEmpty
    }

    /// callback(x, y, z), in g, from the sensor's thread, about 100 times
    /// a second.
    init(callback: @escaping Callback) {
        self.callback = callback
        let t = Thread { [self] in run() }
        t.name = "motion"
        t.start()
        _ = started.wait(timeout: .now() + 5)
    }

    func stop() {
        lock.lock(); running = false; lock.unlock()
    }

    private var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

    private static func devices() -> (IOHIDManager?, [IOHIDDevice]) {
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: [String: Any] = [kIOHIDPrimaryUsagePageKey: 0xFF00, kIOHIDPrimaryUsageKey: 3]
        IOHIDManagerSetDeviceMatching(m, match as CFDictionary)
        guard IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { return (m, []) }
        guard let set = IOHIDManagerCopyDevices(m) as? Set<IOHIDDevice> else { return (m, []) }
        return (m, Array(set))
    }

    /// Sets the sensor drivers streaming (values nil) or back to values;
    /// returns what they were before.
    @discardableResult
    private static func setReporting(_ values: [UInt64: [String: Int]]?) -> [UInt64: [String: Int]] {
        var before: [UInt64: [String: Int]] = [:]
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSPUHIDDriver"), &it) == KERN_SUCCESS else {
            return before
        }
        defer { IOObjectRelease(it) }
        while case let svc = IOIteratorNext(it), svc != 0 {
            var eid: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(svc, &eid)
            var was: [String: Int] = [:]
            for k in props {
                if let v = IORegistryEntryCreateCFProperty(svc, k as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? NSNumber {
                    was[k] = v.intValue
                }
            }
            before[eid] = was
            let want = values == nil ? Dictionary(uniqueKeysWithValues: zip(props, [1, 1, 10000]))
                                     : values![eid] ?? [:]
            for (k, v) in want {
                IORegistryEntrySetCFProperty(svc, k as CFString, NSNumber(value: Int32(v)))
            }
            IOObjectRelease(svc)
        }
        return before
    }

    private func run() {
        saved = Self.setReporting(nil)
        let (m, devs) = Self.devices()
        manager = m
        let loop = CFRunLoopGetCurrent()
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        for dev in devs {
            guard IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { continue }
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
            buffers.append(buf)
            IOHIDDeviceRegisterInputReportCallback(dev, buf, 64, { ctx, _, _, _, _, report, length in
                guard let ctx, length >= 18 else { return }
                let me = Unmanaged<MotionSensor>.fromOpaque(ctx).takeUnretainedValue()
                func i32(_ o: Int) -> Double {
                    let u = UInt32(report[o]) | UInt32(report[o + 1]) << 8 |
                        UInt32(report[o + 2]) << 16 | UInt32(report[o + 3]) << 24
                    return Double(Int32(bitPattern: u)) / 65536
                }
                me.callback(i32(6), i32(10), i32(14))
            }, ctx)
            IOHIDDeviceScheduleWithRunLoop(dev, loop!, CFRunLoopMode.defaultMode.rawValue)
            ok = true
        }
        started.signal()
        while isRunning {
            CFRunLoopRunInMode(.defaultMode, 0.2, false)
        }
        for dev in devs {
            IOHIDDeviceUnscheduleFromRunLoop(dev, loop!, CFRunLoopMode.defaultMode.rawValue)
            IOHIDDeviceClose(dev, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        if let m { IOHIDManagerClose(m, IOOptionBits(kIOHIDOptionsTypeNone)) }
        // Back to the drivers' own settings, which others may rely on.
        Self.setReporting(saved)
        // The buffers stay: a report may still be in flight. They are small.
        withExtendedLifetime(self) {}
    }
}
