#!/usr/bin/env swift
// Renders the Birth app icon (a power glyph rising like a sunrise) to
// AppIcon.iconset PNGs. Run via scripts/make-app.sh; requires macOS.
import AppKit

let sizes: [(name: String, points: Int, scale: Int)] = [
    ("icon_16x16", 16, 1), ("icon_16x16@2x", 16, 2),
    ("icon_32x32", 32, 1), ("icon_32x32@2x", 32, 2),
    ("icon_128x128", 128, 1), ("icon_128x128@2x", 128, 2),
    ("icon_256x256", 256, 1), ("icon_256x256@2x", 256, 2),
    ("icon_512x512", 512, 1), ("icon_512x512@2x", 512, 2),
]

let outputDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

func drawIcon(pixels: CGFloat) -> NSImage {
    let size = NSSize(width: pixels, height: pixels)
    let image = NSImage(size: size)
    image.lockFocus()
    defer { image.unlockFocus() }

    let bounds = NSRect(origin: .zero, size: size)
    // macOS applies the squircle mask itself; leave margin like system icons.
    let inset = pixels * 0.09
    let plate = NSBezierPath(
        roundedRect: bounds.insetBy(dx: inset, dy: inset),
        xRadius: pixels * 0.2,
        yRadius: pixels * 0.2
    )
    NSGradient(colors: [
        NSColor(calibratedRed: 0.07, green: 0.09, blue: 0.16, alpha: 1),
        NSColor(calibratedRed: 0.13, green: 0.17, blue: 0.30, alpha: 1),
    ])?.draw(in: plate, angle: 90)

    // Horizon glow.
    let glowRect = NSRect(
        x: pixels * 0.2,
        y: pixels * 0.16,
        width: pixels * 0.6,
        height: pixels * 0.24
    )
    let glow = NSGradient(colors: [
        NSColor(calibratedRed: 1.0, green: 0.62, blue: 0.26, alpha: 0.55),
        NSColor(calibratedRed: 1.0, green: 0.62, blue: 0.26, alpha: 0.0),
    ])
    glow?.draw(in: NSBezierPath(ovalIn: glowRect), relativeCenterPosition: .zero)

    // Power symbol.
    let config = NSImage.SymbolConfiguration(pointSize: pixels * 0.42, weight: .medium)
    if let symbol = NSImage(systemSymbolName: "power", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let tinted = NSImage(size: symbol.size)
        tinted.lockFocus()
        NSColor.white.set()
        let symbolRect = NSRect(origin: .zero, size: symbol.size)
        symbol.draw(in: symbolRect)
        symbolRect.fill(using: .sourceAtop)
        tinted.unlockFocus()

        let target = NSRect(
            x: (pixels - symbol.size.width) / 2,
            y: (pixels - symbol.size.height) / 2 + pixels * 0.02,
            width: symbol.size.width,
            height: symbol.size.height
        )
        tinted.draw(in: target)
    }

    return image
}

for spec in sizes {
    let pixels = CGFloat(spec.points * spec.scale)
    let image = drawIcon(pixels: pixels)
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff) else { continue }
    rep.size = NSSize(width: spec.points, height: spec.points)
    guard let png = rep.representation(using: .png, properties: [:]) else { continue }
    let url = URL(filePath: outputDir).appendingPathComponent("\(spec.name).png")
    try? png.write(to: url)
}
print("iconset written to \(outputDir)")
