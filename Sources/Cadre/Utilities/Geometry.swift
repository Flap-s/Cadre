import AppKit

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    /// Height of the primary screen, used to flip between Cocoa (bottom-left) and Quartz (top-left) coordinates.
    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    static func withMouse() -> NSScreen {
        let p = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(p, $0.frame, false) } ?? main ?? screens[0]
    }

    static func with(displayID: CGDirectDisplayID) -> NSScreen? {
        screens.first { $0.displayID == displayID }
    }

    /// Cocoa global rect -> rect local to this screen with a top-left origin (ScreenCaptureKit's `sourceRect` space).
    func localTopLeft(fromGlobal r: CGRect) -> CGRect {
        CGRect(x: r.minX - frame.minX, y: frame.maxY - r.maxY, width: r.width, height: r.height)
    }

    func globalRect(fromLocalTopLeft r: CGRect) -> CGRect {
        CGRect(x: frame.minX + r.minX, y: frame.maxY - r.maxY, width: r.width, height: r.height)
    }
}

/// Quartz global (top-left origin, as returned by CGWindowList) -> Cocoa global.
func cocoaRect(fromQuartz r: CGRect) -> CGRect {
    CGRect(x: r.minX, y: NSScreen.primaryHeight - r.maxY, width: r.width, height: r.height)
}

func quartzPoint(fromCocoa p: CGPoint) -> CGPoint {
    CGPoint(x: p.x, y: NSScreen.primaryHeight - p.y)
}

extension CGRect {
    init(corner a: CGPoint, _ b: CGPoint) {
        self.init(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

extension CGPoint {
    func distance(to p: CGPoint) -> CGFloat { hypot(x - p.x, y - p.y) }
    static func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
    static func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
}

/// Distance from `p` to the segment `a`–`b`.
func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
    let dx = b.x - a.x, dy = b.y - a.y
    let len2 = dx * dx + dy * dy
    guard len2 > 0 else { return p.distance(to: a) }
    let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
    return p.distance(to: CGPoint(x: a.x + t * dx, y: a.y + t * dy))
}
