// Renders the disk image window background (660×420 pt) at the scale given as the second argument.
// Usage: swift make-dmg-background.swift out.png 2
import AppKit

let width: CGFloat = 660, height: CGFloat = 420
let scale = CGFloat(Double(CommandLine.arguments[2]) ?? 1)
// Icon centers used by Scripts/dmg-settings.py, measured from the top-left.
let appCenter = CGPoint(x: 180, y: 215), applicationsCenter = CGPoint(x: 480, y: 215)

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: width, height: height)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let flip = { (p: CGPoint) in CGPoint(x: p.x, y: height - p.y) }

// Background: the app icon's blue-to-violet, darkened so Finder's labels stay readable.
NSGradient(colors: [NSColor(srgbRed: 0.10, green: 0.13, blue: 0.32, alpha: 1),
                    NSColor(srgbRed: 0.27, green: 0.13, blue: 0.42, alpha: 1)])!
    .draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: -35)

// Soft glows behind the two icons.
for center in [appCenter, applicationsCenter] {
    let c = flip(center)
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.16), NSColor.white.withAlphaComponent(0)])!
        .draw(in: NSBezierPath(ovalIn: NSRect(x: c.x - 120, y: c.y - 120, width: 240, height: 240)),
              relativeCenterPosition: .zero)
}

func text(_ string: String, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat, centerY: CGFloat) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: NSColor.white.withAlphaComponent(alpha),
        .paragraphStyle: paragraph,
    ]
    let str = NSAttributedString(string: string, attributes: attrs)
    let h = str.size().height
    str.draw(in: NSRect(x: 0, y: height - centerY - h / 2, width: width, height: h))
}

text("Install Cadre", size: 28, weight: .bold, alpha: 1, centerY: 52)
text("Drag Cadre onto the Applications folder", size: 14, weight: .medium, alpha: 0.75, centerY: 86)
text("Then open Cadre from Applications — it lives in your menu bar.", size: 12, weight: .regular, alpha: 0.55, centerY: 386)

// Dashed arrow from the app to Applications.
let start = flip(CGPoint(x: appCenter.x + 88, y: appCenter.y)), end = flip(CGPoint(x: applicationsCenter.x - 92, y: applicationsCenter.y))
let arrow = NSBezierPath()
arrow.move(to: start)
arrow.curve(to: end, controlPoint1: CGPoint(x: start.x + 40, y: start.y + 26), controlPoint2: CGPoint(x: end.x - 40, y: end.y + 26))
arrow.lineWidth = 4
arrow.lineCapStyle = .round
arrow.setLineDash([2, 10], count: 2, phase: 0)
NSColor.white.withAlphaComponent(0.85).setStroke()
arrow.stroke()
let head = NSBezierPath()
head.move(to: CGPoint(x: end.x - 16, y: end.y + 13))
head.line(to: end)
head.line(to: CGPoint(x: end.x - 19, y: end.y - 9))
head.lineWidth = 4
head.lineCapStyle = .round
head.lineJoinStyle = .round
head.stroke()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
