#!/usr/bin/env swift
// Renders Resources/AppIcon.icns and site/favicon.png from site/cat-fabi.svg —
// the same cat the landing page uses — on the app's yellow square. Above 64 px
// the whole cat; at 64 and below only the cross on its rear.
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
    let weight = size <= 128 ? "6" : "3.5"
    let scaled = drawing.replacingOccurrences(of: #"stroke-width="3.5""#, with: #"stroke-width="\#(weight)""#)
    guard let image = NSImage(data: Data(scaled.utf8)) else {
        FileHandle.standardError.write(Data("error: cannot render the cat at \(size)\n".utf8))
        exit(1)
    }
    return image
}

// The rear cross is two strokes of the drawing, marked `class="rear-cross"` in
// the SVG so this script can ask for the part by name instead of by position.
// Its box is measured from those strokes' own endpoints, so the two anchors are
// asserted below: move the cross in the drawing and the assertion fires rather
// than the crop going quietly wrong.
let crossAnchors = ["1424.1987, 436.2081", "1422.7039, 452.3227"]
let crossPadding = 3.0    // room for the round caps at the thickened weight
let crossBox = (
    x: 1422.7039 - crossPadding,
    y: 436.2081 - crossPadding,
    width: 13.9317 + 2 * crossPadding,      // 1436.6356 − 1422.7039
    height: 16.1146 + 2 * crossPadding      // 452.3227 − 436.2081
)

/// The cat's rear cross alone, lifted out of the drawing.
func rearCross() -> NSImage {
    let groups = drawing.components(separatedBy: "<g ")
        .filter { $0.hasPrefix(#"class="rear-cross""#) }
        .compactMap { chunk in (chunk.range(of: "</g>")).map { "<g " + chunk[..<$0.upperBound] } }
    guard groups.count == 2, crossAnchors.allSatisfy(drawing.contains) else {
        FileHandle.standardError.write(Data("error: \(source.path) no longer has the two rear-cross strokes at their measured anchors\n".utf8))
        exit(1)
    }
    let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="\(crossBox.width)" height="\(crossBox.height)" \
        viewBox="\(crossBox.x) \(crossBox.y) \(crossBox.width) \(crossBox.height)" \
        stroke-linecap="round" stroke-linejoin="round">\(groups.joined())</svg>
        """
        .replacingOccurrences(of: #"stroke-width="3.5""#, with: #"stroke-width="4.5""#)
    guard let image = NSImage(data: Data(svg.utf8)) else {
        FileHandle.standardError.write(Data("error: cannot render the rear cross\n".utf8))
        exit(1)
    }
    return image
}

/// What the icon shows at `size`, and how tall it stands on the 1024 grid.
///
/// Above 64 px the whole cat. At 64 and below only the rear cross: a cat seen
/// from behind is a dozen strokes, and on a 16 px grid they run into each other
/// into grey mush however thick the pen. Two crossing strokes stay a cross —
/// and it is the mark you recognise the drawing by anyway.
func glyph(for size: Int) -> (image: NSImage, height: Double) {
    size <= 64 ? (rearCross(), 450) : (cat(for: size), 600)
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

    // The drawing is black line art. Draw it into the alpha channel, then
    // flood it with ink through `sourceIn` — that recolours the strokes
    // without touching the SVG.
    let (drawn, tall) = glyph(for: size)
    let drawnHeight = tall * scale
    let drawnWidth = drawnHeight * (drawn.size.width / drawn.size.height)
    let frame = NSRect(
        x: (Double(size) - drawnWidth) / 2,
        y: (Double(size) - drawnHeight) / 2,
        width: drawnWidth,
        height: drawnHeight
    )
    context.cgContext.beginTransparencyLayer(auxiliaryInfo: nil)
    drawn.draw(in: frame)
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
// down to 16 or 32 themselves, so what they shrink is the cross — which is what
// a tab has room for — rather than a cat turning into hairlines.
guard let png = render(size: 64).representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("error: cannot encode the favicon\n".utf8))
    exit(1)
}
try png.write(to: favicon)
print("Wrote \(favicon.path) (\(png.count) bytes)")
