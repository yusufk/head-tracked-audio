#!/usr/bin/env swift
// Generates HeadTrack's AppIcon.appiconset PNGs.
// Usage: swift Tools/make_icon.swift HeadTrack/Resources/Assets.xcassets/AppIcon.appiconset
import AppKit

func render(pixels: Int) -> Data {
    let s = CGFloat(pixels)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // macOS icon grid: 824/1024 tile centred in the canvas.
    let tile = NSRect(x: s * 100 / 1024, y: s * 100 / 1024, width: s * 824 / 1024, height: s * 824 / 1024)
    let path = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.2237, yRadius: tile.width * 0.2237)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = s * 0.02
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.01)
    shadow.set()
    NSColor.black.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(colors: [NSColor(red: 0.36, green: 0.30, blue: 0.95, alpha: 1),
                        NSColor(red: 0.07, green: 0.62, blue: 0.88, alpha: 1)])!
        .draw(in: path, angle: -60)

    // Glyph: same geometry as MenuBarIcon (18pt grid), scaled to the tile.
    let k = tile.width / 18 * 0.92
    let ox = tile.midX - 9 * k, oy = tile.midY - 9.5 * k
    func P(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: ox + x * k, y: oy + y * k) }
    func R(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
        NSRect(x: ox + x * k, y: oy + y * k, width: w * k, height: h * k)
    }
    NSColor.white.setFill(); NSColor.white.setStroke()
    let cx: CGFloat = 9, cy: CGFloat = 7.5
    NSBezierPath(ovalIn: R(cx - 3.8, cy - 4.2, 7.6, 8.4)).fill()

    let band = NSBezierPath()
    band.appendArc(withCenter: P(cx, cy), radius: 6.6 * k, startAngle: -5, endAngle: 185, clockwise: false)
    band.lineWidth = 1.5 * k
    band.lineCapStyle = .round
    band.stroke()

    for x in [cx - 6.6, cx + 6.6] {
        NSBezierPath(roundedRect: R(x - 1.6, cy - 3.2, 3.2, 5.6), xRadius: 1.4 * k, yRadius: 1.4 * k).fill()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let dir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.appiconset"
try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

var images: [String] = []
for pt in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(pt)x\(pt)\(scale == 2 ? "@2x" : "").png"
        try render(pixels: pt * scale).write(to: URL(fileURLWithPath: "\(dir)/\(name)"))
        images.append("""
            {"filename":"\(name)","idiom":"mac","scale":"\(scale)x","size":"\(pt)x\(pt)"}
        """)
    }
}
let contents = "{\"images\":[\(images.joined(separator: ",\n"))],\"info\":{\"author\":\"xcode\",\"version\":1}}"
try contents.write(toFile: "\(dir)/Contents.json", atomically: true, encoding: .utf8)
try "{\"info\":{\"author\":\"xcode\",\"version\":1}}"
    .write(toFile: "\(dir)/../Contents.json", atomically: true, encoding: .utf8)
print("wrote \(images.count) icons to \(dir)")
