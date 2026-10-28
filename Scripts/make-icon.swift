// Renders Cadre's app icon (1024×1024 PNG) to the path given as the first argument.
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
    NSGradient(colors: [NSColor(srgbRed: 0.22, green: 0.36, blue: 0.98, alpha: 1),
                        NSColor(srgbRed: 0.56, green: 0.27, blue: 0.95, alpha: 1)])!.draw(in: shape, angle: -60)

    // Viewfinder corners
    NSColor.white.setStroke()
    let inset: CGFloat = 250, arm: CGFloat = 130
    let corners = NSBezierPath()
    corners.lineWidth = 46
    corners.lineCapStyle = .round
    corners.lineJoinStyle = .round
    let lo = inset, hi = size - inset
    for (x, y, dx, dy) in [(lo, lo, 1.0, 1.0), (hi, lo, -1.0, 1.0), (lo, hi, 1.0, -1.0), (hi, hi, -1.0, -1.0)] {
        corners.move(to: NSPoint(x: x + dx * arm, y: y))
        corners.line(to: NSPoint(x: x, y: y))
        corners.line(to: NSPoint(x: x, y: y + dy * arm))
    }
    corners.stroke()

    // Shutter dot
    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(x: size / 2 - 70, y: size / 2 - 70, width: 140, height: 140)).fill()
    return true
}

let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
