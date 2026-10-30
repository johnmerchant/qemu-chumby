// swift-tools-version:6.0
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Chumby.app: chumby-emu's native macOS front end. Build the app bundle
// with ./build-app; `swift test` runs the protocol tests.

import Foundation
import PackageDescription

// With only the Command Line Tools (no Xcode), SwiftPM doesn't hand the
// compiler swift-testing's macro plugin once the package uses SwiftUI:
// point it there.
let clt = "/Library/Developer/CommandLineTools"
let cltTesting = clt + "/usr/lib/swift/host/plugins/testing"
let selected = (try? FileManager.default.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link")) ?? clt
let testSettings: [SwiftSetting] =
    selected.hasPrefix(clt) && FileManager.default.fileExists(atPath: cltTesting)
    ? [.unsafeFlags(["-plugin-path", cltTesting])] : []

let package = Package(
    name: "Chumby",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Chumby", targets: ["Chumby"]),
    ],
    targets: [
        // QMP, RFB, the console and the launch logic: no UI, unit-tested.
        .target(name: "ChumbyKit"),
        // The app: AppKit windows with SwiftUI inside.
        .executableTarget(name: "Chumby", dependencies: ["ChumbyKit"]),
        .testTarget(name: "ChumbyKitTests", dependencies: ["ChumbyKit"], swiftSettings: testSettings),
    ],
    swiftLanguageModes: [.v5]
)
