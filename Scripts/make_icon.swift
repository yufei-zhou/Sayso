// Draws the Sayso app icon (1024×1024 PNG): white squircle, two violet quote marks, a teal wavy underline.
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
// Work in SVG-style coordinates (origin top-left).
ctx.translateBy(x: 0, y: size)
ctx.scaleBy(x: 1, y: -1)

func color(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

// Base: macOS icon grid leaves ~10% margin; soft shadow under a white rounded square.
let base = CGRect(x: 100, y: 100, width: 824, height: 824)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 28, color: CGColor(gray: 0, alpha: 0.18))
ctx.addPath(CGPath(roundedRect: base, cornerWidth: 186, cornerHeight: 186, transform: nil))
ctx.setFillColor(color(0xFFFFFF))
ctx.fillPath()
ctx.restoreGState()
ctx.addPath(CGPath(roundedRect: base.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 185, cornerHeight: 185, transform: nil))
ctx.setStrokeColor(color(0xE3E3EA))
ctx.setLineWidth(3)
ctx.strokePath()

// Opening quote marks: a round head with a tail sweeping up and right.
func quote(x: CGFloat, y: CGFloat) {
    let r: CGFloat = 70
    let head = CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)
    ctx.addEllipse(in: head)
    let tail = CGMutablePath()
    tail.move(to: CGPoint(x: x - r, y: y - 6))
    tail.addCurve(to: CGPoint(x: x + 46, y: y - 205), control1: CGPoint(x: x - r - 6, y: y - 120), control2: CGPoint(x: x - 20, y: y - 185))
    tail.addQuadCurve(to: CGPoint(x: x + 62, y: y - 172), control: CGPoint(x: x + 70, y: y - 196))
    tail.addCurve(to: CGPoint(x: x + 10, y: y - 60), control1: CGPoint(x: x + 20, y: y - 150), control2: CGPoint(x: x + 2, y: y - 110))
    tail.closeSubpath()
    ctx.addPath(tail)
    ctx.setFillColor(color(0x534AB7))
    ctx.fillPath()
}
// The artwork spans from the tips of the tails (205 above the quote centres) to the bottom of the wave. `drop`
// moves all of it down so that span sits in the middle of the square (it used to sit about 30 px high).
let drop: CGFloat = 30
quote(x: 400, y: 486 + drop)
quote(x: 616, y: 486 + drop)

// Wavy underline.
let wave = CGMutablePath()
let startX: CGFloat = 318, endX: CGFloat = 706, y: CGFloat = 652 + drop, amp: CGFloat = 13
let step = (endX - startX) / 8
wave.move(to: CGPoint(x: startX, y: y))
for i in 0..<8 {
    let x0 = startX + CGFloat(i) * step
    wave.addQuadCurve(to: CGPoint(x: x0 + step, y: y), control: CGPoint(x: x0 + step / 2, y: i % 2 == 0 ? y - 2 * amp : y + 2 * amp))
}
ctx.addPath(wave)
ctx.setStrokeColor(color(0x1D9E75))
ctx.setLineWidth(32)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.strokePath()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
