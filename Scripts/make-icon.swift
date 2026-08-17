#!/usr/bin/env swift
// Renders Resources/AppIcon.icns and site/favicon.png from site/cat-fabi.svg —
// the same cat the landing page uses — on the app's yellow square.
//
// Usage: Scripts/make-icon.swift
//
// Both outputs are committed, so a normal build needs neither this script nor a
// working SVG renderer. Run it only when the drawing or the colours change.
// No dependencies: AppKit has read SVG since Ventura, iconutil ships with the
// CLT. The colours below are written as OKLCH rather than as hex, in the same
// notation styles.css uses, so a change to the brand ramp transfers by reading.

import AppKit
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let source = root.appendingPathComponent("site/cat-fabi.svg")
let destination = root.appendingPathComponent("Resources/AppIcon.icns")
let favicon = root.appendingPathComponent("site/favicon.png")

/// OKLCH → sRGB. Lightness 0…1, chroma in OKLab units, hue in degrees.
func oklch(_ lightness: Double, _ chroma: Double, _ hueDegrees: Double) -> NSColor {
    let hue = hueDegrees * .pi / 180
    let a = chroma * cos(hue)
    let b = chroma * sin(hue)

    let l = pow(lightness + 0.3963377774 * a + 0.2158037573 * b, 3)
    let m = pow(lightness - 0.1055613458 * a - 0.0638541728 * b, 3)
    let s = pow(lightness - 0.0894841775 * a - 1.2914855480 * b, 3)

    let linear = [
        4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
        -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
        -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s,
    ]
    // Out-of-gamut components are clamped, not scaled: every colour used here
    // is inside sRGB, so a clamp that fires means a token was mistyped.
    let encoded = linear.map { channel -> CGFloat in
        let clamped = min(max(channel, 0), 1)
        let value = clamped <= 0.0031308 ? clamped * 12.92 : 1.055 * pow(clamped, 1 / 2.4) - 0.055
        return CGFloat(value)
    }
    return NSColor(srgbRed: encoded[0], green: encoded[1], blue: encoded[2], alpha: 1)
}

// The plate is the app's own yellow: NSColor.systemYellow, the colour the pill
// shows between 70 and 89 %, measured under Aqua as #FFCC00. The site's ginger
// sits at hue 55 and reads as Claude's orange (#D97757, hue 39) at icon size —
// too close for an icon that has to be told apart from Claude's in the Dock.
// Written as OKLCH rather than as systemYellow itself so the render does not
// change with the system appearance.
let yellow = oklch(0.865, 0.177, 90)        // = systemYellow, #FFCC00
let yellowDeep = oklch(0.78, 0.165, 82)     // shading, one step down the ramp
let ink = oklch(0.20, 0.05, 45)             // between --ink and --ginger-ink

guard let drawing = try? String(contentsOf: source, encoding: .utf8),
      drawing.contains(#"stroke-width="3.5""#)
else {
    FileHandle.standardError.write(Data("error: cannot read \(source.path), or its strokes are no longer 3.5\n".utf8))
    exit(1)
}

/// The cat at a stroke weight that survives `size`.
///
/// A line drawing scaled to 32 px with its authored 3.5 stroke renders under
/// one pixel wide and turns to grey mush. Thickening the stroke as the icon
/// shrinks keeps the silhouette readable; the large sizes stay untouched.
func cat(for size: Int) -> NSImage {
    let weight = size <= 64 ? "9" : size <= 128 ? "6" : "3.5"
    let scaled = drawing.replacingOccurrences(of: #"stroke-width="3.5""#, with: #"stroke-width="\#(weight)""#)
    guard let image = NSImage(data: Data(scaled.utf8)) else {
        FileHandle.standardError.write(Data("error: cannot render the cat at \(size)\n".utf8))
        exit(1)
    }
    return image
}

/// Draws the icon at `size` points into a fresh bitmap.
///
/// Geometry follows Apple's macOS grid: the artwork sits on a 1024 canvas,
/// inset 100 on every side, corner radius 185.4. Keeping the ratios means the
/// icon lines up with the system's own icons at every size.
func render(size: Int) -> NSBitmapImageRep {
    let scale = Double(size) / 1024
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context

    let plate = NSRect(x: 100 * scale, y: 100 * scale, width: 824 * scale, height: 824 * scale)
    let squircle = NSBezierPath(roundedRect: plate, xRadius: 185.4 * scale, yRadius: 185.4 * scale)
    squircle.addClip()
    NSGradient(starting: yellow, ending: yellowDeep)?.draw(in: plate, angle: -90)

    // The cat is a black line drawing. Draw it into the alpha channel, then
    // flood it with ink through `sourceIn` — that recolours the strokes
    // without touching the SVG.
    let cat = cat(for: size)
    let catHeight = 600.0 * scale
    let catWidth = catHeight * (cat.size.width / cat.size.height)
    let frame = NSRect(
        x: (Double(size) - catWidth) / 2,
        y: (Double(size) - catHeight) / 2,
        width: catWidth,
        height: catHeight
    )
    context.cgContext.beginTransparencyLayer(auxiliaryInfo: nil)
    cat.draw(in: frame)
    ink.setFill()
    frame.fill(using: .sourceIn)
    context.cgContext.endTransparencyLayer()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("AppIcon-\(ProcessInfo.processInfo.processIdentifier).iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for points in [16, 32, 128, 256, 512] {
    for factor in [1, 2] {
        let rep = render(size: points * factor)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("error: cannot encode \(points)@\(factor)x\n".utf8))
            exit(1)
        }
        let suffix = factor == 1 ? "" : "@2x"
        try png.write(to: iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
    }
}

try FileManager.default.createDirectory(
    at: destination.deletingLastPathComponent(),
    withIntermediateDirectories: true
)
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["--convert", "icns", iconset.path, "--output", destination.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("error: iconutil failed\n".utf8))
    exit(1)
}
try FileManager.default.removeItem(at: iconset)

let bytes = (try Data(contentsOf: destination)).count
print("Wrote \(destination.path) (\(bytes) bytes)")

// The tab icon is the app icon, not a second drawing. 64 px: browsers scale it
// down to 16 or 32 themselves, and at 64 the stroke is already thickened, so
// what they shrink is a readable silhouette rather than hairlines.
guard let png = render(size: 64).representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("error: cannot encode the favicon\n".utf8))
    exit(1)
}
try png.write(to: favicon)
print("Wrote \(favicon.path) (\(png.count) bytes)")
