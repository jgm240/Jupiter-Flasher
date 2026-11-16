// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CoreGraphics

// Renders the Jupiter Flasher icon (1024x1024 PNG) to argv[1]:
// a banded gas-giant planet with a lightning bolt ("flash") across it, on a deep-space squircle.
let S: CGFloat = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError("no context") }

func col(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(colorSpace: cs, components: [r / 255, g / 255, b / 255, a])! }
func grad(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: cs, colors: stops.map { $0.1 } as CFArray, locations: stops.map { $0.0 })!
}

// --- App-icon body: 824pt squircle centred in the canvas, with a soft drop shadow ---
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let squircle = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: col(0, 0, 0, 0.45))
ctx.addPath(squircle); ctx.setFillColor(col(20, 16, 48)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(squircle); ctx.clip()

// Deep-space background
ctx.drawLinearGradient(grad([(0, col(52, 28, 98)), (0.55, col(24, 18, 64)), (1, col(10, 8, 30))]),
                       start: CGPoint(x: 300, y: 924), end: CGPoint(x: 700, y: 100), options: [])

// A few stars (deterministic)
var seed: UInt64 = 0x9E3779B97F4A7C15
func rnd() -> CGFloat { seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17; return CGFloat(seed % 10_000) / 10_000 }
for _ in 0..<46 {
    let x = 120 + rnd() * 784, y = 120 + rnd() * 784
    let r = 1.5 + rnd() * 3.2
    ctx.setFillColor(col(255, 255, 255, 0.25 + rnd() * 0.55))
    ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
}

// --- Planet ---
let c = CGPoint(x: 512, y: 500), R: CGFloat = 318
let disc = CGRect(x: c.x - R, y: c.y - R, width: R * 2, height: R * 2)

// Atmosphere glow behind the planet
ctx.drawRadialGradient(grad([(0, col(255, 150, 70, 0.55)), (1, col(255, 150, 70, 0))]),
                       startCenter: c, startRadius: R * 0.9, endCenter: c, endRadius: R * 1.38, options: [])

ctx.saveGState()
ctx.addEllipse(in: disc); ctx.clip()

// Cloud bands, top to bottom; edges wobble a little so they read as weather, not stripes.
let bands: [(CGFloat, CGColor)] = [
    (0.00, col(232, 196, 150)), (0.10, col(206, 142, 92)),  (0.19, col(240, 214, 176)),
    (0.30, col(190, 112, 66)),  (0.40, col(236, 196, 150)), (0.50, col(168, 88, 52)),
    (0.60, col(228, 178, 128)), (0.71, col(200, 124, 76)),  (0.82, col(240, 212, 172)),
    (0.92, col(196, 134, 92)),
]
let top = c.y + R, height = R * 2
for (i, b) in bands.enumerated() {
    let y0 = top - height * b.0
    let y1 = i + 1 < bands.count ? top - height * bands[i + 1].0 : c.y - R - 2
    let p = CGMutablePath()
    let steps = 40
    p.move(to: CGPoint(x: c.x - R - 4, y: y0))
    for s in 0...steps {
        let x = c.x - R - 4 + (R * 2 + 8) * CGFloat(s) / CGFloat(steps)
        p.addLine(to: CGPoint(x: x, y: y0 + sin(x / 38 + CGFloat(i) * 1.7) * 6 + sin(x / 15 + CGFloat(i)) * 2.2))
    }
    p.addLine(to: CGPoint(x: c.x + R + 4, y: y1 - 10)); p.addLine(to: CGPoint(x: c.x - R - 4, y: y1 - 10)); p.closeSubpath()
    ctx.addPath(p); ctx.setFillColor(b.1); ctx.fillPath()
}
// Great Red Spot
ctx.saveGState()
ctx.translateBy(x: c.x + 118, y: c.y - 118); ctx.rotate(by: 0.12)
ctx.setFillColor(col(188, 70, 44)); ctx.fillEllipse(in: CGRect(x: -62, y: -30, width: 124, height: 60))
ctx.setStrokeColor(col(150, 52, 34, 0.7)); ctx.setLineWidth(5); ctx.strokeEllipse(in: CGRect(x: -62, y: -30, width: 124, height: 60))
ctx.setFillColor(col(214, 104, 70, 0.8)); ctx.fillEllipse(in: CGRect(x: -34, y: -15, width: 68, height: 30))
ctx.restoreGState()

// Sphere shading: light from the upper left, deep terminator on the lower right.
ctx.drawRadialGradient(grad([(0, col(255, 240, 220, 0.30)), (0.45, col(255, 255, 255, 0)), (1, col(30, 8, 40, 0.80))]),
                       startCenter: CGPoint(x: c.x - R * 0.40, y: c.y + R * 0.42), startRadius: 0,
                       endCenter: CGPoint(x: c.x + R * 0.10, y: c.y - R * 0.05), endRadius: R * 1.18, options: [.drawsAfterEndLocation])
ctx.restoreGState()

// Thin rim light
ctx.setStrokeColor(col(255, 214, 170, 0.35)); ctx.setLineWidth(3); ctx.strokeEllipse(in: disc.insetBy(dx: 1.5, dy: 1.5))

// --- Lightning bolt ---
func boltPath() -> CGPath {
    let pts: [CGPoint] = [(618, 894), (322, 478), (484, 478), (398, 150), (712, 590), (548, 590)].map { CGPoint(x: $0.0, y: $0.1) }
    let path = CGMutablePath()
    path.addLines(between: pts); path.closeSubpath()
    return path
}
let bolt = boltPath()

// Glow
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 70, color: col(255, 214, 90, 0.95))
ctx.addPath(bolt); ctx.setFillColor(col(255, 226, 120)); ctx.fillPath()
ctx.restoreGState()
// Dark under-edge so the bolt separates from the bright bands
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 6, height: -10), blur: 18, color: col(40, 10, 50, 0.7))
ctx.addPath(bolt); ctx.setFillColor(col(255, 226, 120)); ctx.fillPath()
ctx.restoreGState()
// Body gradient (white-hot top to amber bottom)
ctx.saveGState()
ctx.addPath(bolt); ctx.clip()
ctx.drawLinearGradient(grad([(0, col(255, 255, 250)), (0.5, col(255, 238, 150)), (1, col(255, 178, 40))]),
                       start: CGPoint(x: 520, y: 894), end: CGPoint(x: 520, y: 150), options: [])
ctx.restoreGState()
ctx.addPath(bolt); ctx.setStrokeColor(col(255, 250, 225, 0.9)); ctx.setLineWidth(5); ctx.setLineJoin(.round); ctx.strokePath()

ctx.restoreGState()   // end squircle clip

// Subtle top highlight on the squircle edge
ctx.saveGState()
ctx.addPath(squircle); ctx.clip()
ctx.setStrokeColor(col(255, 255, 255, 0.16)); ctx.setLineWidth(4)
ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 2, dy: 2), cornerWidth: 183, cornerHeight: 183, transform: nil)); ctx.strokePath()
ctx.restoreGState()

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
