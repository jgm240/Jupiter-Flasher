// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

// Renders a 1024px icon (blue gradient squircle + drive glyph) and writes it to argv[1].
let size = 1024.0
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let rect = NSRect(x: 40, y: 40, width: size - 80, height: size - 80)
let path = NSBezierPath(roundedRect: rect, xRadius: 200, yRadius: 200)
NSGradient(colors: [NSColor(red: 0.20, green: 0.55, blue: 1.0, alpha: 1), NSColor(red: 0.05, green: 0.25, blue: 0.75, alpha: 1)])!
    .draw(in: path, angle: -90)
let cfg = NSImage.SymbolConfiguration(pointSize: 520, weight: .semibold)
if let sym = NSImage(systemSymbolName: "externaldrive.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
    let tinted = NSImage(size: sym.size, flipped: false) { r in
        sym.draw(in: r); NSColor.white.set(); r.fill(using: .sourceAtop); return true
    }
    tinted.draw(at: NSPoint(x: (size - tinted.size.width) / 2, y: (size - tinted.size.height) / 2), from: .zero, operation: .sourceOver, fraction: 1)
}
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
