// Generates AppIcon.icns: a frosted-glass note pane floating over a vivid
// desktop-colored tile — the app's Liquid Glass look, as an icon.
// Run via Scripts/make_app.sh (or: swift Scripts/make_icon.swift).
import AppKit
import CoreImage

func renderBackground(pixels: Int, tile: NSBezierPath, rect: NSRect) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    tile.addClip()
    // Deep base
    NSGradient(colors: [
        NSColor(calibratedRed: 0.05, green: 0.12, blue: 0.32, alpha: 1),
        NSColor(calibratedRed: 0.10, green: 0.35, blue: 0.52, alpha: 1),
    ])!.draw(in: rect, angle: -60)
    // Vivid blobs (a saturated "desktop" behind the glass)
    func blob(_ color: NSColor, _ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) {
        let g = NSGradient(starting: color, ending: color.withAlphaComponent(0))!
        g.draw(in: NSBezierPath(ovalIn: NSRect(x: rect.minX + rect.width*cx - r,
                                               y: rect.minY + rect.height*cy - r,
                                               width: r*2, height: r*2)),
               relativeCenterPosition: .zero)
    }
    blob(NSColor(calibratedRed: 1.00, green: 0.58, blue: 0.15, alpha: 1.0), 0.82, 0.80, rect.width*0.46)
    blob(NSColor(calibratedRed: 0.15, green: 0.90, blue: 0.55, alpha: 0.95), 0.14, 0.28, rect.width*0.42)
    blob(NSColor(calibratedRed: 1.00, green: 0.25, blue: 0.50, alpha: 0.95), 0.20, 0.88, rect.width*0.38)
    blob(NSColor(calibratedRed: 0.35, green: 0.45, blue: 1.00, alpha: 0.95), 0.86, 0.16, rect.width*0.40)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func blurred(_ rep: NSBitmapImageRep, radius: Double) -> NSImage {
    let ci = CIImage(bitmapImageRep: rep)!
    let f = CIFilter(name: "CIGaussianBlur")!
    f.setValue(ci, forKey: kCIInputImageKey)
    f.setValue(radius, forKey: kCIInputRadiusKey)
    let out = f.outputImage!.cropped(to: ci.extent)
    let repOut = NSCIImageRep(ciImage: out)
    let img = NSImage(size: NSSize(width: rep.pixelsWide, height: rep.pixelsHigh))
    img.addRepresentation(repOut)
    return img
}

func drawIcon(pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!

    let s = CGFloat(pixels)
    let inset = s * 0.09
    let rect = NSRect(x: inset, y: inset, width: s - 2*inset, height: s - 2*inset)
    let radius = rect.width * 0.225
    let tile = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    let bg = renderBackground(pixels: pixels, tile: tile, rect: rect)
    let bgBlurred = blurred(bg, radius: Double(s) * 0.045)
    let full = NSRect(x: 0, y: 0, width: s, height: s)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Outer shadow
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.30)
    shadow.shadowBlurRadius = s * 0.028
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    shadow.set()
    NSColor.black.setFill()
    tile.fill()
    NSShadow().set()

    // Sharp vivid background
    bg.draw(in: full)

    // The glass note pane
    let paneInsetX = rect.width * 0.14
    let paneInsetY = rect.height * 0.14
    let pane = NSRect(x: rect.minX + paneInsetX, y: rect.minY + paneInsetY,
                      width: rect.width - 2*paneInsetX, height: rect.height - 2*paneInsetY)
    let paneRadius = pane.width * 0.16
    let panePath = NSBezierPath(roundedRect: pane, xRadius: paneRadius, yRadius: paneRadius)

    NSGraphicsContext.current?.saveGraphicsState()
    panePath.addClip()
    bgBlurred.draw(in: full, from: full, operation: .sourceOver, fraction: 1)
    NSColor(calibratedWhite: 1, alpha: 0.20).setFill()
    panePath.fill()
    // top sheen
    let sheen = NSGradient(colors: [NSColor(calibratedWhite: 1, alpha: 0.28),
                                    NSColor(calibratedWhite: 1, alpha: 0.0)])!
    sheen.draw(in: NSRect(x: pane.minX, y: pane.midY, width: pane.width, height: pane.height/2), angle: 90)
    NSGraphicsContext.current?.restoreGraphicsState()

    // Rim light
    let rim = NSBezierPath(roundedRect: pane.insetBy(dx: s*0.004, dy: s*0.004),
                           xRadius: paneRadius, yRadius: paneRadius)
    rim.lineWidth = s * 0.008
    NSColor(calibratedWhite: 1, alpha: 0.75).setStroke()
    rim.stroke()

    // Note content: three ink lines, longest on top like a note
    let ink = NSColor(calibratedWhite: 1, alpha: 0.92)
    let lineH = pane.height * 0.075
    let contentX = pane.minX + pane.width * 0.14
    ink.setFill()
    for (i, widthFactor) in [0.62, 0.48, 0.36].enumerated() {
        let y = pane.minY + pane.height * (0.70 - CGFloat(i) * 0.21) - lineH / 2
        NSBezierPath(roundedRect: NSRect(x: contentX, y: y,
                                         width: pane.width * CGFloat(widthFactor),
                                         height: lineH),
                     xRadius: lineH / 2, yRadius: lineH / 2).fill()
    }

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
