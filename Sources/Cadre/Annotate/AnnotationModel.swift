import AppKit
import CoreImage

enum AnnotationTool: String, CaseIterable {
    case select, arrow, line, rectangle, filledRectangle, ellipse, text, pencil, highlighter
    case counter, blur, pixelate, spotlight, crop

    var title: String {
        switch self {
        case .select: return "Select (V)"
        case .arrow: return "Arrow (A)"
        case .line: return "Line (L)"
        case .rectangle: return "Rectangle (R)"
        case .filledRectangle: return "Filled Rectangle (F)"
        case .ellipse: return "Ellipse (O)"
        case .text: return "Text (T)"
        case .pencil: return "Pencil (P)"
        case .highlighter: return "Highlighter (H)"
        case .counter: return "Counter (N)"
        case .blur: return "Blur (B)"
        case .pixelate: return "Pixelate (X)"
        case .spotlight: return "Spotlight (S)"
        case .crop: return "Crop (C)"
        }
    }

    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .arrow: return "arrow.up.right"
        case .line: return "line.diagonal"
        case .rectangle: return "rectangle"
        case .filledRectangle: return "rectangle.fill"
        case .ellipse: return "circle"
        case .text: return "textformat"
        case .pencil: return "scribble"
        case .highlighter: return "highlighter"
        case .counter: return "1.circle"
        case .blur: return "drop"
        case .pixelate: return "checkerboard.rectangle"
        case .spotlight: return "flashlight.on.fill"
        case .crop: return "crop"
        }
    }

    var shortcut: Character {
        switch self {
        case .select: return "v"
        case .arrow: return "a"
        case .line: return "l"
        case .rectangle: return "r"
        case .filledRectangle: return "f"
        case .ellipse: return "o"
        case .text: return "t"
        case .pencil: return "p"
        case .highlighter: return "h"
        case .counter: return "n"
        case .blur: return "b"
        case .pixelate: return "x"
        case .spotlight: return "s"
        case .crop: return "c"
        }
    }

    var isFreehand: Bool { self == .pencil || self == .highlighter }
    var isRegion: Bool { self == .blur || self == .pixelate || self == .spotlight }
}

/// One annotation, in image pixel coordinates (top-left origin).
struct Annotation: Identifiable {
    let id = UUID()
    var tool: AnnotationTool
    var points: [CGPoint]
    var color: NSColor
    var lineWidth: CGFloat
    var text = ""
    var fontSize: CGFloat = 0
    var number = 0

    var start: CGPoint { points.first ?? .zero }
    var end: CGPoint { points.last ?? .zero }
    var rect: CGRect { CGRect(corner: start, end) }

    var counterRadius: CGFloat { fontSize * 0.75 }

    func textAttributes() -> [NSAttributedString.Key: Any] {
        return [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: color,
            .strokeColor: color.isLight ? NSColor.black.withAlphaComponent(0.7) : NSColor.white,
            .strokeWidth: -4.0,
        ]
    }

    var textSize: CGSize {
        let size = NSAttributedString(string: text.isEmpty ? " " : text, attributes: textAttributes()).size()
        return CGSize(width: ceil(size.width), height: ceil(size.height))
    }

    /// Area used for hit-testing and the selection outline.
    var bounds: CGRect {
        switch tool {
        case .text: return CGRect(origin: start, size: textSize)
        case .counter:
            return CGRect(x: start.x - counterRadius, y: start.y - counterRadius, width: counterRadius * 2, height: counterRadius * 2)
        case .pencil, .highlighter:
            let xs = points.map(\.x), ys = points.map(\.y)
            return CGRect(x: xs.min() ?? 0, y: ys.min() ?? 0, width: (xs.max() ?? 0) - (xs.min() ?? 0),
                          height: (ys.max() ?? 0) - (ys.min() ?? 0)).insetBy(dx: -lineWidth, dy: -lineWidth)
        default:
            return rect.insetBy(dx: -lineWidth / 2, dy: -lineWidth / 2)
        }
    }

    func hitTest(_ p: CGPoint, tolerance: CGFloat) -> Bool {
        switch tool {
        case .arrow, .line:
            return distance(from: p, toSegment: start, end) <= lineWidth / 2 + tolerance
        case .pencil, .highlighter:
            guard bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(p) else { return false }
            return zip(points, points.dropFirst()).contains { distance(from: p, toSegment: $0, $1) <= lineWidth + tolerance }
        case .rectangle, .ellipse:
            let outer = rect.insetBy(dx: -lineWidth - tolerance, dy: -lineWidth - tolerance)
            let inner = rect.insetBy(dx: lineWidth + tolerance, dy: lineWidth + tolerance)
            return outer.contains(p) && !(inner.width > 0 && inner.height > 0 && inner.contains(p))
        default:
            return bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(p)
        }
    }

    mutating func offset(by d: CGPoint) {
        points = points.map { $0 + d }
    }
}

enum BackgroundAspect: String, CaseIterable, Identifiable {
    case auto = "Auto", square = "1:1", fourThree = "4:3", sixteenNine = "16:9", nineSixteen = "9:16"
    var id: String { rawValue }
    var ratio: CGFloat? {
        switch self {
        case .auto: return nil
        case .square: return 1
        case .fourThree: return 4.0 / 3
        case .sixteenNine: return 16.0 / 9
        case .nineSixteen: return 9.0 / 16
        }
    }
}

/// The "beautify" background: padding, gradient, rounded corners and shadow around the screenshot.
struct CanvasBackground: Equatable {
    var enabled = false
    var padding: CGFloat = 64
    var cornerRadius: CGFloat = 12
    var shadow = true
    var preset = 0
    var aspect: BackgroundAspect = .auto

    static let presets: [(NSColor, NSColor)] = [
        (NSColor(srgbRed: 0.40, green: 0.49, blue: 0.98, alpha: 1), NSColor(srgbRed: 0.74, green: 0.36, blue: 0.93, alpha: 1)),
        (NSColor(srgbRed: 0.98, green: 0.55, blue: 0.40, alpha: 1), NSColor(srgbRed: 0.96, green: 0.30, blue: 0.53, alpha: 1)),
        (NSColor(srgbRed: 0.20, green: 0.80, blue: 0.70, alpha: 1), NSColor(srgbRed: 0.16, green: 0.45, blue: 0.86, alpha: 1)),
        (NSColor(srgbRed: 0.99, green: 0.83, blue: 0.35, alpha: 1), NSColor(srgbRed: 0.98, green: 0.47, blue: 0.27, alpha: 1)),
        (NSColor(srgbRed: 0.55, green: 0.89, blue: 0.45, alpha: 1), NSColor(srgbRed: 0.15, green: 0.62, blue: 0.47, alpha: 1)),
        (NSColor(srgbRed: 0.16, green: 0.17, blue: 0.24, alpha: 1), NSColor(srgbRed: 0.33, green: 0.30, blue: 0.47, alpha: 1)),
        (NSColor(srgbRed: 0.93, green: 0.94, blue: 0.96, alpha: 1), NSColor(srgbRed: 0.80, green: 0.83, blue: 0.88, alpha: 1)),
        (NSColor.white, NSColor.white),
    ]

    func layout(imageSize: CGSize, scale: CGFloat) -> (canvas: CGSize, imageOrigin: CGPoint) {
        guard enabled else { return (imageSize, .zero) }
        let pad = padding * scale
        var w = imageSize.width + pad * 2, h = imageSize.height + pad * 2
        if let ratio = aspect.ratio {
            if w / h < ratio { w = h * ratio } else { h = w / ratio }
        }
        w = w.rounded(); h = h.rounded()
        return (CGSize(width: w, height: h),
                CGPoint(x: ((w - imageSize.width) / 2).rounded(), y: ((h - imageSize.height) / 2).rounded()))
    }
}

/// Draws an image plus annotations into a flipped (top-left origin) context.
@MainActor
final class AnnotationRenderer {
    private(set) var base: CGImage
    let scale: CGFloat
    private var pixelated: CGImage?
    private var blurred: CGImage?
    private let ciContext = CIContext()

    init(base: CGImage, scale: CGFloat) {
        self.base = base
        self.scale = scale
    }

    var imageSize: CGSize { CGSize(width: base.width, height: base.height) }

    func setBase(_ image: CGImage) {
        base = image
        pixelated = nil
        blurred = nil
    }

    private func processed(_ tool: AnnotationTool) -> CGImage? {
        if tool == .pixelate, let pixelated { return pixelated }
        if tool == .blur, let blurred { return blurred }
        let input = CIImage(cgImage: base)
        let output: CIImage
        if tool == .pixelate {
            output = input.applyingFilter("CIPixellate", parameters: [
                kCIInputScaleKey: max(8, 12 * scale),
                kCIInputCenterKey: CIVector(x: 0, y: 0),
            ]).cropped(to: input.extent)
        } else {
            output = input.clampedToExtent().applyingGaussianBlur(sigma: 10 * scale).cropped(to: input.extent)
        }
        let result = ciContext.createCGImage(output, from: input.extent)
        if tool == .pixelate { pixelated = result } else { blurred = result }
        return result
    }

    static func drawImage(_ image: CGImage, in rect: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }

    /// Background + image + annotations. The context must be flipped and NSGraphicsContext.current must wrap it.
    func render(annotations: [Annotation], background: CanvasBackground, in ctx: CGContext) {
        let layout = background.layout(imageSize: imageSize, scale: scale)
        let imageRect = CGRect(origin: layout.imageOrigin, size: imageSize)

        if background.enabled {
            let colors = CanvasBackground.presets[min(background.preset, CanvasBackground.presets.count - 1)]
            if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                         colors: [colors.0.cgColor, colors.1.cgColor] as CFArray, locations: [0, 1]) {
                ctx.saveGState()
                ctx.clip(to: CGRect(origin: .zero, size: layout.canvas))
                ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: layout.canvas.width, y: layout.canvas.height), options: [])
                ctx.restoreGState()
            }
            let radius = background.cornerRadius * scale
            let path = CGPath(roundedRect: imageRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
            if background.shadow {
                ctx.saveGState()
                ctx.setShadow(offset: CGSize(width: 0, height: 10 * scale), blur: 40 * scale,
                              color: NSColor.black.withAlphaComponent(0.35).cgColor)
                ctx.addPath(path)
                ctx.setFillColor(NSColor.white.cgColor)
                ctx.fillPath()
                ctx.restoreGState()
            }
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            Self.drawImage(base, in: imageRect, ctx: ctx)
            ctx.restoreGState()
        } else {
            Self.drawImage(base, in: imageRect, ctx: ctx)
        }

        ctx.saveGState()
        ctx.translateBy(x: imageRect.minX, y: imageRect.minY)
        drawAnnotations(annotations, ctx: ctx)
        ctx.restoreGState()
    }

    func drawAnnotations(_ annotations: [Annotation], ctx: CGContext) {
        let full = CGRect(origin: .zero, size: imageSize)
        for a in annotations where a.tool == .blur || a.tool == .pixelate {
            guard let img = processed(a.tool) else { continue }
            ctx.saveGState()
            ctx.clip(to: a.rect)
            Self.drawImage(img, in: full, ctx: ctx)
            ctx.restoreGState()
        }

        let spots = annotations.filter { $0.tool == .spotlight }
        if !spots.isEmpty {
            ctx.saveGState()
            ctx.addRect(full)
            for s in spots {
                let r = s.rect
                let radius = min(12 * scale, r.width / 2, r.height / 2)
                ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
            }
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
            ctx.fillPath(using: .evenOdd)
            ctx.restoreGState()
        }

        for a in annotations where !a.tool.isRegion {
            draw(a, ctx: ctx)
        }
    }

    private func draw(_ a: Annotation, ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        let shadow = { ctx.setShadow(offset: CGSize(width: 0, height: 1.5 * self.scale), blur: 4 * self.scale,
                                     color: NSColor.black.withAlphaComponent(0.3).cgColor) }
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setStrokeColor(a.color.cgColor)
        ctx.setFillColor(a.color.cgColor)
        ctx.setLineWidth(a.lineWidth)

        switch a.tool {
        case .arrow:
            shadow()
            drawArrow(from: a.start, to: a.end, width: a.lineWidth, ctx: ctx)
        case .line:
            shadow()
            ctx.move(to: a.start)
            ctx.addLine(to: a.end)
            ctx.strokePath()
        case .rectangle:
            shadow()
            let radius = min(4 * scale, a.rect.width / 2, a.rect.height / 2)
            ctx.addPath(CGPath(roundedRect: a.rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.strokePath()
        case .filledRectangle:
            let radius = min(4 * scale, a.rect.width / 2, a.rect.height / 2)
            ctx.addPath(CGPath(roundedRect: a.rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.fillPath()
        case .ellipse:
            shadow()
            ctx.strokeEllipse(in: a.rect)
        case .pencil, .highlighter:
            if a.tool == .highlighter {
                ctx.setBlendMode(.multiply)
                ctx.setStrokeColor(a.color.withAlphaComponent(0.45).cgColor)
                ctx.setLineCap(.square)
            } else {
                shadow()
            }
            guard let first = a.points.first else { return }
            ctx.move(to: first)
            if a.points.count == 1 { ctx.addLine(to: first) }
            // Smooth the stroke through midpoints.
            for (p, q) in zip(a.points, a.points.dropFirst()) {
                ctx.addQuadCurve(to: CGPoint(x: (p.x + q.x) / 2, y: (p.y + q.y) / 2), control: p)
            }
            if let last = a.points.last { ctx.addLine(to: last) }
            ctx.strokePath()
        case .text:
            NSAttributedString(string: a.text, attributes: a.textAttributes()).draw(at: a.start)
        case .counter:
            shadow()
            let r = a.counterRadius
            ctx.fillEllipse(in: CGRect(x: a.start.x - r, y: a.start.y - r, width: r * 2, height: r * 2))
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: r * 1.1, weight: .bold),
                .foregroundColor: a.color.isLight ? NSColor.black : NSColor.white,
            ]
            let str = NSAttributedString(string: "\(a.number)", attributes: attrs)
            let size = str.size()
            str.draw(at: CGPoint(x: a.start.x - size.width / 2, y: a.start.y - size.height / 2))
        default:
            break
        }
    }

    private func drawArrow(from a: CGPoint, to b: CGPoint, width w: CGFloat, ctx: CGContext) {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = hypot(dx, dy)
        guard length > 1 else { return }
        let head = min(length * 0.6, max(w * 4.5, 14 * scale))
        let half = head * 0.55
        let ux = dx / length, uy = dy / length
        let px = -uy, py = ux
        let base = CGPoint(x: b.x - ux * head, y: b.y - uy * head)

        let path = CGMutablePath()
        path.move(to: CGPoint(x: a.x + px * w * 0.2, y: a.y + py * w * 0.2))
        path.addLine(to: CGPoint(x: base.x + px * w * 0.6, y: base.y + py * w * 0.6))
        path.addLine(to: CGPoint(x: base.x + px * half, y: base.y + py * half))
        path.addLine(to: b)
        path.addLine(to: CGPoint(x: base.x - px * half, y: base.y - py * half))
        path.addLine(to: CGPoint(x: base.x - px * w * 0.6, y: base.y - py * w * 0.6))
        path.addLine(to: CGPoint(x: a.x - px * w * 0.2, y: a.y - py * w * 0.2))
        path.closeSubpath()
        ctx.addPath(path)
        ctx.fillPath()
    }

    /// Final flattened image.
    func export(annotations: [Annotation], background: CanvasBackground) -> CGImage? {
        let layout = background.layout(imageSize: imageSize, scale: scale)
        let w = Int(layout.canvas.width), h = Int(layout.canvas.height)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: base.colorSpace.usableRGB,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        render(annotations: annotations, background: background, in: ctx)
        NSGraphicsContext.current = previous
        return ctx.makeImage()
    }
}

extension NSColor {
    /// Perceived luminance above ~0.7 (white, yellow…): use dark text on top of it.
    var isLight: Bool {
        guard let c = usingColorSpace(.sRGB) else { return false }
        return 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent > 0.7
    }
}
