#!/usr/bin/env swift
//
// Draws DeskMate.icns from code.
//
// A checked-in .icns is a binary nobody can review or re-colour, and the icon
// should track the Celadon palette in DSTheme rather than drift from it. Run
// this when the palette changes:
//
//     swift packaging/make-icon.swift packaging/DeskMate.icns
//

import AppKit
import Foundation

// Celadon, matching DSTheme.
let accent     = NSColor(srgbRed: 0.42, green: 0.66, blue: 0.56, alpha: 1)
let accentDeep = NSColor(srgbRed: 0.18, green: 0.38, blue: 0.32, alpha: 1)
let paper      = NSColor(srgbRed: 0.957, green: 0.976, blue: 0.969, alpha: 1)

/// One icon face at a given pixel size. Everything is expressed as a fraction
/// of `size` so the 16pt and 1024pt faces are the same drawing, not two.
func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return image
    }
    ctx.setShouldAntialias(true)

    // macOS icons sit in a squircle inset from the canvas; without the inset
    // the art collides with neighbours in the Dock.
    let inset = size * 0.085
    let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let squircle = NSBezierPath(roundedRect: rect,
                                xRadius: rect.width * 0.225,
                                yRadius: rect.width * 0.225)

    ctx.saveGState()
    squircle.addClip()
    let gradient = NSGradient(colors: [accent, accentDeep])!
    gradient.draw(in: rect, angle: -90)
    ctx.restoreGState()

    // A screen, because that is what the thing watches.
    let screenW = rect.width * 0.52
    let screenH = screenW * 0.68
    let screen = CGRect(
        x: rect.midX - screenW / 2,
        y: rect.midY - screenH / 2 + rect.height * 0.055,
        width: screenW,
        height: screenH)
    let screenPath = NSBezierPath(roundedRect: screen,
                                  xRadius: screen.height * 0.13,
                                  yRadius: screen.height * 0.13)
    paper.setFill()
    screenPath.fill()

    // The stand, so it reads as a monitor rather than a card at small sizes.
    let neckW = rect.width * 0.075
    let neckH = rect.height * 0.055
    let neck = CGRect(x: rect.midX - neckW / 2, y: screen.minY - neckH, width: neckW, height: neckH)
    paper.setFill()
    NSBezierPath(rect: neck).fill()

    let baseW = rect.width * 0.245
    let baseH = rect.height * 0.033
    let base = CGRect(x: rect.midX - baseW / 2, y: neck.minY - baseH, width: baseW, height: baseH)
    NSBezierPath(roundedRect: base, xRadius: baseH / 2, yRadius: baseH / 2).fill()

    // Three bars of "work" on the screen, descending in width. Skipped below
    // 64px, where they turn into grey mud and the silhouette reads better clean.
    if size >= 64 {
        let barH = screen.height * 0.105
        let gap = screen.height * 0.115
        let left = screen.minX + screen.width * 0.135
        let widths: [CGFloat] = [0.73, 0.55, 0.40]
        var y = screen.maxY - screen.height * 0.33
        for (i, w) in widths.enumerated() {
            let bar = CGRect(x: left, y: y, width: screen.width * w, height: barH)
            // The last bar is the one being automated — accent, not ink.
            (i == widths.count - 1 ? accent : accentDeep).withAlphaComponent(i == 2 ? 1.0 : 0.32).setFill()
            NSBezierPath(roundedRect: bar, xRadius: barH / 2, yRadius: barH / 2).fill()
            y -= barH + gap
        }
    }

    image.unlockFocus()
    return image
}

func png(_ image: NSImage, pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let output = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "packaging/DeskMate.icns"

let iconset = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("DeskMate-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// The exact set `iconutil` expects. A missing face makes it fail outright.
let faces: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),      ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),      ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),   ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),   ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),   ("icon_512x512@2x.png", 1024),
]

for face in faces {
    let art = drawIcon(size: CGFloat(face.pixels))
    try png(art, pixels: face.pixels).write(to: iconset.appendingPathComponent(face.name))
}

let convert = Process()
convert.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
convert.arguments = ["-c", "icns", iconset.path, "-o", output]
try convert.run()
convert.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)

guard convert.terminationStatus == 0 else {
    FileHandle.standardError.write("iconutil failed\n".data(using: .utf8)!)
    exit(1)
}
print("wrote \(output)")
