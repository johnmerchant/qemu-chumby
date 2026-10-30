// SPDX-License-Identifier: GPL-2.0-or-later
//
// swift make-icon.swift DIR.iconset: draws Chumby.app's icon, a Chumby
// Classic face on (a soft leather body with its little screen), at the
// sizes iconutil wants. build-app runs it.

import AppKit

let dir = CommandLine.arguments[1]

func draw(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // The macOS icon grid: a rounded square inset by about a tenth.
    let body = NSRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8)
    let shape = NSBezierPath(roundedRect: body, xRadius: s * 0.18, yRadius: s * 0.18)
    NSGradient(starting: NSColor(calibratedRed: 0.86, green: 0.74, blue: 0.56, alpha: 1),
               ending: NSColor(calibratedRed: 0.62, green: 0.47, blue: 0.31, alpha: 1))!
        .draw(in: shape, angle: -90)
    // Stitching round the edge.
    let stitch = NSBezierPath(roundedRect: body.insetBy(dx: s * 0.035, dy: s * 0.035),
                              xRadius: s * 0.15, yRadius: s * 0.15)
    stitch.lineWidth = max(1, s * 0.008)
    stitch.setLineDash([s * 0.025, s * 0.018], count: 2, phase: 0)
    NSColor(white: 1, alpha: 0.55).setStroke()
    stitch.stroke()
    // The screen, 4:3, in its bezel.
    let sw = s * 0.5, sh = sw * 3 / 4
    let screen = NSRect(x: (s - sw) / 2, y: s * 0.36, width: sw, height: sh)
    NSColor(white: 0.12, alpha: 1).setFill()
    NSBezierPath(roundedRect: screen.insetBy(dx: -s * 0.025, dy: -s * 0.025),
                 xRadius: s * 0.03, yRadius: s * 0.03).fill()
    NSGradient(starting: NSColor(calibratedRed: 0.20, green: 0.55, blue: 0.95, alpha: 1),
               ending: NSColor(calibratedRed: 0.55, green: 0.85, blue: 1.0, alpha: 1))!
        .draw(in: NSBezierPath(rect: screen), angle: 90)
    // A smile on the screen.
    let smile = NSBezierPath()
    smile.appendArc(withCenter: NSPoint(x: screen.midX, y: screen.midY + sh * 0.12), radius: sh * 0.28,
                    startAngle: 200, endAngle: 340)
    smile.lineWidth = max(1, s * 0.022)
    smile.lineCapStyle = .round
    NSColor.white.setStroke()
    smile.stroke()
    // The top button.
    NSColor(white: 0.95, alpha: 0.9).setFill()
    NSBezierPath(roundedRect: NSRect(x: s * 0.44, y: s * 0.86, width: s * 0.12, height: s * 0.03),
                 xRadius: s * 0.015, yRadius: s * 0.015).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    for k in [1, 2] {
        let name = k == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! draw(base * k).write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
    }
}
