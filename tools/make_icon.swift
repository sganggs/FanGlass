// make_icon.swift — renders the FanGlass app icon (1024×1024 PNG) at the given path.
import AppKit

guard CommandLine.arguments.count > 1 else { exit(1) }
let outPath = CommandLine.arguments[1]
let size: CGFloat = 1024

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
) else { exit(1) }
rep.size = NSSize(width: size, height: size)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// background: rounded-rect vertical gradient
let rect = CGRect(x: 0, y: 0, width: size, height: size)
let rounded = NSBezierPath(roundedRect: rect, xRadius: size * 0.2237, yRadius: size * 0.2237)
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.10, green: 0.42, blue: 0.95, alpha: 1),
    NSColor(calibratedRed: 0.20, green: 0.70, blue: 1.00, alpha: 1),
])!
rounded.addClip()
gradient.draw(in: rounded, angle: -55)

// glass sheen on top
let sheen = NSGradient(colors: [
    NSColor.white.withAlphaComponent(0.35),
    NSColor.white.withAlphaComponent(0.0),
])!
sheen.draw(in: NSBezierPath(rect: CGRect(x: 0, y: size * 0.55, width: size, height: size * 0.45)), angle: -90)

// fan blades: 5 rotated petals
ctx.saveGState()
ctx.translateBy(x: size / 2, y: size / 2)
for i in 0..<5 {
    ctx.saveGState()
    ctx.rotate(by: CGFloat(i) * .pi * 2 / 5)
    let blade = NSBezierPath()
    blade.move(to: .zero)
    blade.curve(to: CGPoint(x: size * 0.30, y: -size * 0.34),
                controlPoint1: CGPoint(x: size * 0.30, y: size * 0.02),
                controlPoint2: CGPoint(x: size * 0.34, y: -size * 0.16))
    blade.curve(to: .zero,
                controlPoint1: CGPoint(x: size * 0.06, y: -size * 0.30),
                controlPoint2: CGPoint(x: -size * 0.02, y: -size * 0.12))
    NSColor.white.withAlphaComponent(0.92).setFill()
    blade.fill()
    ctx.restoreGState()
}
// hub
NSColor(calibratedRed: 0.10, green: 0.42, blue: 0.95, alpha: 1).setFill()
NSBezierPath(ovalIn: CGRect(x: -size * 0.075, y: -size * 0.075, width: size * 0.15, height: size * 0.15)).fill()
NSColor.white.withAlphaComponent(0.95).setFill()
NSBezierPath(ovalIn: CGRect(x: -size * 0.045, y: -size * 0.045, width: size * 0.09, height: size * 0.09)).fill()
ctx.restoreGState()

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try! png.write(to: URL(fileURLWithPath: outPath))
