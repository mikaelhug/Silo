// Renders the Silo app icon to a 1024×1024 PNG using CoreGraphics (no external deps).
// Usage: swift Scripts/make-icon.swift <output.png>
import AppKit
import CoreGraphics

let size = 1024
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!

NSGraphicsContext.saveGraphicsState()
let gctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = gctx
let cg = gctx.cgContext
let S = CGFloat(size)
let rgb = CGColorSpaceCreateDeviceRGB()

// Rounded-rect background with a diagonal indigo→cyan gradient.
let bg = CGPath(roundedRect: CGRect(x: 0, y: 0, width: S, height: S).insetBy(dx: S * 0.06, dy: S * 0.06),
                cornerWidth: S * 0.225, cornerHeight: S * 0.225, transform: nil)
cg.saveGState()
cg.addPath(bg)
cg.clip()
let grad = CGGradient(colorsSpace: rgb,
                      colors: [CGColor(red: 0.31, green: 0.27, blue: 0.90, alpha: 1),
                               CGColor(red: 0.02, green: 0.71, blue: 0.83, alpha: 1)] as CFArray,
                      locations: [0, 1])!
cg.drawLinearGradient(grad, start: CGPoint(x: 0, y: S), end: CGPoint(x: S, y: 0), options: [])
cg.restoreGState()

// Three staggered rounded squares = isolated per-game prefixes.
func square(cx: CGFloat, cy: CGFloat, side: CGFloat, alpha: CGFloat) {
    let rect = CGRect(x: cx - side / 2, y: cy - side / 2, width: side, height: side)
    cg.addPath(CGPath(roundedRect: rect, cornerWidth: side * 0.2, cornerHeight: side * 0.2, transform: nil))
    cg.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: alpha))
    cg.fillPath()
}
let side = S * 0.40
square(cx: S * 0.40, cy: S * 0.40, side: side, alpha: 0.22)
square(cx: S * 0.47, cy: S * 0.47, side: side, alpha: 0.45)
square(cx: S * 0.55, cy: S * 0.55, side: side, alpha: 0.97)

// Play triangle in the front square = launcher.
let c = CGPoint(x: S * 0.55, y: S * 0.55)
let t = side * 0.26
cg.beginPath()
cg.move(to: CGPoint(x: c.x - t * 0.5, y: c.y + t))
cg.addLine(to: CGPoint(x: c.x - t * 0.5, y: c.y - t))
cg.addLine(to: CGPoint(x: c.x + t * 0.9, y: c.y))
cg.closePath()
cg.setFillColor(CGColor(red: 0.31, green: 0.27, blue: 0.90, alpha: 1))
cg.fillPath()

NSGraphicsContext.restoreGraphicsState()

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
guard let png = rep.representation(using: .png, properties: [:]) else {
    fputs("failed to encode PNG\n", stderr); exit(1)
}
try! png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
