// Generates AppIcon.icns: a glassy sticky-note tile with note lines and a
// checkmark. Run via Scripts/make_app.sh (or: swift Scripts/make_icon.swift).
import AppKit

func drawIcon(pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let s = CGFloat(pixels)
    let inset = s * 0.09
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let radius = rect.width * 0.225

    // Soft shadow
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = s * 0.03
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    shadow.set()

    // Tile: warm glassy gradient
    let tile = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    NSGradient(colors: [
        NSColor(calibratedRed: 1.00, green: 0.90, blue: 0.52, alpha: 1),
        NSColor(calibratedRed: 0.97, green: 0.76, blue: 0.26, alpha: 1),
    ])!.draw(in: tile, angle: -90)

    NSShadow().set() // reset shadow for inner drawing

    // Glass sheen across the top
    NSGraphicsContext.current?.saveGraphicsState()
    tile.addClip()
    let sheen = NSBezierPath()
    sheen.move(to: NSPoint(x: rect.minX, y: rect.maxY))
    sheen.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
    sheen.line(to: NSPoint(x: rect.maxX, y: rect.minY + rect.height * 0.72))
    sheen.line(to: NSPoint(x: rect.minX, y: rect.minY + rect.height * 0.52))
    sheen.close()
    NSColor(calibratedWhite: 1, alpha: 0.22).setFill()
    sheen.fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    // Note lines
    let ink = NSColor(calibratedRed: 0.30, green: 0.25, blue: 0.10, alpha: 0.72)
    let lineHeight = rect.height * 0.052
    let lineX = rect.minX + rect.width * 0.16
    for (i, widthFactor) in [0.56, 0.44].enumerated() {
        let y = rect.minY + rect.height * (0.60 - CGFloat(i) * 0.16)
        let line = NSBezierPath(
            roundedRect: NSRect(x: lineX, y: y,
                                width: rect.width * widthFactor, height: lineHeight),
            xRadius: lineHeight / 2, yRadius: lineHeight / 2
        )
        ink.setFill()
        line.fill()
    }

    // Checkmark badge
    let badgeSize = rect.width * 0.20
    let badgeRect = NSRect(x: lineX, y: rect.minY + rect.height * 0.70,
                           width: badgeSize, height: badgeSize)
    ink.setFill()
    NSBezierPath(ovalIn: badgeRect).fill()
    let check = NSBezierPath()
    check.lineWidth = badgeSize * 0.14
    check.lineCapStyle = .round
    check.lineJoinStyle = .round
    check.move(to: NSPoint(x: badgeRect.minX + badgeSize * 0.28,
                           y: badgeRect.minY + badgeSize * 0.52))
    check.line(to: NSPoint(x: badgeRect.minX + badgeSize * 0.45,
                           y: badgeRect.minY + badgeSize * 0.32))
    check.line(to: NSPoint(x: badgeRect.minX + badgeSize * 0.74,
                           y: badgeRect.minY + badgeSize * 0.70))
    NSColor(calibratedRed: 1.00, green: 0.92, blue: 0.60, alpha: 1).setStroke()
    check.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let iconsetURL = URL(fileURLWithPath: "Resources/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconsetURL)
try! FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let name = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
        let rep = drawIcon(pixels: pixels)
        try! rep.representation(using: .png, properties: [:])!
            .write(to: iconsetURL.appendingPathComponent(name))
    }
}

let task = Process()
task.launchPath = "/usr/bin/iconutil"
task.arguments = ["-c", "icns", iconsetURL.path, "-o", "Resources/AppIcon.icns"]
task.launch()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "AppIcon.icns written" : "iconutil failed")
