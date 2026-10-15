// Renders the OpenFlo app icon: `swift icon.swift out.png` (1024×1024).
import AppKit

let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// macOS icon grid: 824pt squircle centred, with a soft drop shadow.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
NSColor.black.setFill()
shape.fill()
ctx.restoreGState()

// Warm charcoal gradient fill.
shape.addClip()
NSGradient(colors: [NSColor(red: 0.20, green: 0.18, blue: 0.17, alpha: 1),
                    NSColor(red: 0.07, green: 0.065, blue: 0.06, alpha: 1)])!.draw(in: tile, angle: -90)

// Waveform: rounded bars, tallest in the middle, cream to warm orange.
let heights: [CGFloat] = [150, 290, 440, 560, 440, 290, 150]
let barW: CGFloat = 62, gap: CGFloat = 34
let total = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
var x = tile.midX - total / 2
let grad = NSGradient(colors: [NSColor(red: 1.0, green: 0.97, blue: 0.91, alpha: 1),
                               NSColor(red: 1.0, green: 0.62, blue: 0.32, alpha: 1)])!
for h in heights {
    let bar = NSBezierPath(roundedRect: CGRect(x: x, y: tile.midY - h / 2, width: barW, height: h), xRadius: barW / 2, yRadius: barW / 2)
    grad.draw(in: bar, angle: -90)
    x += barW + gap
}
img.unlockFocus()

let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
