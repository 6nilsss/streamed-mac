import AppKit
// Renders a 1024px app icon: dark rounded square, red play triangle, small grid hint.
let s: CGFloat = 1024
let img = NSImage(size: NSSize(width: s, height: s))
img.lockFocus()
let r = NSRect(x: 100, y: 100, width: 824, height: 824)
let bg = NSBezierPath(roundedRect: r, xRadius: 185, yRadius: 185)
NSGradient(starting: NSColor(srgbRed: 0.10, green: 0.13, blue: 0.20, alpha: 1), ending: NSColor(srgbRed: 0.04, green: 0.06, blue: 0.09, alpha: 1))!.draw(in: bg, angle: -90)
// 2x2 grid of faint tiles
NSColor(white: 1, alpha: 0.07).setFill()
for i in 0..<4 {
    let x: CGFloat = 200 + CGFloat(i % 2) * 320, y: CGFloat = 200 + CGFloat(i / 2) * 320
    NSBezierPath(roundedRect: NSRect(x: x, y: y, width: 300, height: 300), xRadius: 40, yRadius: 40).fill()
}
let tri = NSBezierPath()
tri.move(to: NSPoint(x: 400, y: 300))
tri.line(to: NSPoint(x: 400, y: 724))
tri.line(to: NSPoint(x: 760, y: 512))
tri.close()
tri.lineJoinStyle = .round
NSColor(srgbRed: 0.898, green: 0.282, blue: 0.302, alpha: 1).setFill()
tri.fill()
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
