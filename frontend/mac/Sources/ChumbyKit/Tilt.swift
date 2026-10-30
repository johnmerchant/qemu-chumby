// SPDX-License-Identifier: GPL-2.0-or-later
//
// The accelerometer's view of the Chumby's pose: gravity along its axes,
// in milli-g (the machine's accel-x, accel-y and accel-z). Upright and
// still is the machine's default, +1 g on Z.

import Foundation

public struct Tilt: Equatable, Sendable {
    /// Forward and back, -90 to 90 degrees.
    public var pitch: Double
    /// Left and right, -180 to 180 degrees.
    public var roll: Double

    public init(pitch: Double, roll: Double) {
        self.pitch = pitch
        self.roll = roll
    }

    public static let upright = Tilt(pitch: 0, roll: 0)
    public static let poses: [(String, Tilt)] = [
        ("Upright", Tilt(pitch: 0, roll: 0)),
        ("Face Up", Tilt(pitch: -90, roll: 0)),
        ("On Its Side", Tilt(pitch: 0, roll: 90)),
        ("Upside Down", Tilt(pitch: 0, roll: 180)),
    ]

    public var gravity: [Int] {
        let p = pitch * .pi / 180, r = roll * .pi / 180
        return [Int((1000 * sin(r) * cos(p)).rounded()),
                Int((1000 * sin(p)).rounded()),
                Int((1000 * cos(r) * cos(p)).rounded())]
    }

    /// The pose a reading of gravity says (still: no shaking in it).
    public init(gravity g: [Int]) {
        let c = g.map { min(1, max(-1, Double($0) / 1000)) }
        pitch = (asin(c[1]) * 180 / .pi).rounded()
        roll = (c[0] != 0 || c[2] != 0) ? (atan2(c[0], c[2]) * 180 / .pi).rounded() : 0
    }

    /// A shake: offsets from gravity, 60 ms apart.
    public static let shakeSteps: [(Int, Int)] = [
        (1800, 0), (-1800, 0), (1500, 300), (-1500, -300), (900, 0), (-900, 0), (0, 0),
    ]

    /// The Mac's motion sensor reads -1 g on Z lying flat, in g; the Chumby
    /// standing still reads +1 g.
    public static func fromMac(x: Double, y: Double, z: Double) -> [Int] {
        [Int((-x * 1000).rounded()), Int((-y * 1000).rounded()), Int((-z * 1000).rounded())]
    }
}
