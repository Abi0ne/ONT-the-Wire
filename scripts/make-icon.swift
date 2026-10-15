// Draws the app icon (an RJ45 plug lit from inside, like fibre) and writes
// Resources/AppIcon.icns.
// Usage: swift scripts/make-icon.swift [output-dir-for-preview-png]
import AppKit

let size: CGFloat = 1024
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

func gradient(_ colors: [CGColor]) -> CGGradient {
    CGGradient(colorsSpace: srgb, colors: colors as CFArray, locations: nil)!
}

/// Strokes `path` as a glowing light line (outer halo, inner glow, core).
func glowStroke(_ ctx: CGContext, _ path: CGPath, width: CGFloat) {
    for (w, alpha, blur) in [(width * 4, 0.16, width * 3), (width * 2, 0.4, width * 1.5), (width, 1.0, width * 0.6)] {
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: blur, color: color(0x34E1FF, 0.9))
        ctx.addPath(path)
        ctx.setLineWidth(w)
        ctx.setLineCap(.round)
        ctx.setStrokeColor(color(0xA5F7FF, alpha))
        ctx.strokePath()
        ctx.restoreGState()
    }
}

func drawIcon(in ctx: CGContext) {
    // macOS icon grid: 824 pt rounded square centred in 1024, radius ~185.
    let body = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824),
                      cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
    ctx.addPath(body)
    ctx.setFillColor(color(0x0A0F2E))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    ctx.drawLinearGradient(gradient([color(0x22337A), color(0x0A0F2E)]),
                           start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    // Cable: translucent jacket with a core of light.
    let jacket = CGMutablePath()
    jacket.move(to: CGPoint(x: 512, y: 262))
    jacket.addLine(to: CGPoint(x: 512, y: 40))
    // The light core runs on into the plug, which glows from it.
    let cable = CGMutablePath()
    cable.move(to: CGPoint(x: 512, y: 470))
    cable.addLine(to: CGPoint(x: 512, y: 40))
    ctx.saveGState()
    ctx.addPath(jacket)
    ctx.setLineWidth(96)
    ctx.setStrokeColor(color(0xFFFFFF, 0.12))
    ctx.strokePath()
    ctx.restoreGState()
    glowStroke(ctx, cable, width: 18)

    // Boot: tapers from the plug to the cable.
    let boot = CGMutablePath()
    boot.move(to: CGPoint(x: 392, y: 372))
    boot.addLine(to: CGPoint(x: 632, y: 372))
    boot.addLine(to: CGPoint(x: 572, y: 262))
    boot.addLine(to: CGPoint(x: 452, y: 262))
    boot.closeSubpath()
    ctx.saveGState()
    ctx.addPath(boot)
    ctx.setFillColor(color(0x6FEFFF, 0.16))
    ctx.fillPath()
    ctx.addPath(boot)
    ctx.setLineWidth(10)
    ctx.setLineJoin(.round)
    ctx.setStrokeColor(color(0xE8FDFF, 0.75))
    ctx.strokePath()
    ctx.restoreGState()

    // Plug body, lit from inside.
    let plug = CGPath(roundedRect: CGRect(x: 302, y: 372, width: 420, height: 400),
                      cornerWidth: 48, cornerHeight: 48, transform: nil)
    ctx.saveGState()
    ctx.addPath(plug)
    ctx.clip()
    let light = CGGradient(colorsSpace: srgb, colors: [color(0x6FEFFF, 0.75), color(0x2A5BFF, 0.15)] as CFArray,
                           locations: [0, 1])!
    ctx.drawRadialGradient(light, startCenter: CGPoint(x: 512, y: 470), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 470), endRadius: 320, options: [])
    ctx.restoreGState()
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 24, color: color(0x34E1FF, 0.8))
    ctx.addPath(plug)
    ctx.setLineWidth(14)
    ctx.setStrokeColor(color(0xE8FDFF))
    ctx.strokePath()
    ctx.restoreGState()

    // Eight gold contacts at the tip.
    for i in 0..<8 {
        let pin = CGPath(roundedRect: CGRect(x: 340 + CGFloat(i) * 44, y: 630, width: 24, height: 104),
                         cornerWidth: 6, cornerHeight: 6, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 8, color: color(0xFFC857, 0.7))
        ctx.addPath(pin)
        ctx.setFillColor(color(0xFFCF5C))
        ctx.fillPath()
        ctx.restoreGState()
    }
    ctx.restoreGState()
}

func png(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    ctx.scaleBy(x: CGFloat(pixels) / size, y: CGFloat(pixels) / size)
    drawIcon(in: ctx)
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    try png(pixels: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try png(pixels: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
if CommandLine.arguments.count > 1 {
    try png(pixels: 1024).write(to: URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("AppIcon-preview.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Creato Resources/AppIcon.icns" : "iconutil non riuscito")
