// swift-tools-version:6.0
// SPDX-License-Identifier: GPL-2.0-or-later
//
// chumby-emu's native macOS front end: the protocols it speaks to QEMU.
// `swift test` runs their tests.

import Foundation
import PackageDescription

// With only the Command Line Tools (no Xcode), SwiftPM doesn't always
// hand the compiler swift-testing's macro plugin: point it there.
let clt = "/Library/Developer/CommandLineTools"
let cltTesting = clt + "/usr/lib/swift/host/plugins/testing"
let selected = (try? FileManager.default.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link")) ?? clt
let testSettings: [SwiftSetting] =
    selected.hasPrefix(clt) && FileManager.default.fileExists(atPath: cltTesting)
    ? [.unsafeFlags(["-plugin-path", cltTesting])] : []

let package = Package(
    name: "Chumby",
    platforms: [.macOS(.v14)],
    targets: [
        // QMP, RFB, the console and the launch logic: no UI, unit-tested.
        .target(name: "ChumbyKit"),
        .testTarget(name: "ChumbyKitTests", dependencies: ["ChumbyKit"], swiftSettings: testSettings),
    ],
    swiftLanguageModes: [.v5]
)
