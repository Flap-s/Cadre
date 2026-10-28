import AppKit
import ScreenCaptureKit

struct Captured {
    let image: CGImage
    /// Pixels per point.
    let scale: CGFloat
}

enum CaptureError: LocalizedError {
    case noDisplay, noWindow

    var errorDescription: String? {
        switch self {
        case .noDisplay: return "The display is no longer available."
        case .noWindow: return "The window is no longer available."
        }
    }
}

/// Our own windows that should still appear in captures (pins, the desktop-icons cover, the
/// recording camera bubble…). Every other Cadre window is excluded.
@MainActor
enum OwnWindows {
    static var capturable: Set<CGWindowID> {
        DesktopIconsHider.shared.windowIDs
            .union(PinManager.shared.windowIDs)
            .union(ScreenRecorder.shared.overlayWindowIDs)
    }
}

@MainActor
enum ScreenCapturer {
    static func content() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }

    static func filter(display: SCDisplay, content: SCShareableContent, keeping keep: Set<CGWindowID>) -> SCContentFilter {
        let pid = ProcessInfo.processInfo.processIdentifier
        let me = content.applications.filter { $0.processID == pid }
        let kept = content.windows.filter { keep.contains($0.windowID) }
        return SCContentFilter(display: display, excludingApplications: me, exceptingWindows: kept)
    }

    /// Captures a whole screen, or `rect` (screen-local points, top-left origin) of it.
    static func captureScreen(_ screen: NSScreen, rect: CGRect? = nil, showCursor: Bool = false) async throws -> Captured {
        let content = try await content()
        guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else {
            throw CaptureError.noDisplay
        }
        let filter = filter(display: display, content: content, keeping: OwnWindows.capturable)
        let scale = CGFloat(filter.pointPixelScale)
        let region = rect ?? CGRect(origin: .zero, size: screen.frame.size)

        let config = SCStreamConfiguration()
        if rect != nil { config.sourceRect = region }
        config.width = max(1, Int((region.width * scale).rounded()))
        config.height = max(1, Int((region.height * scale).rounded()))
        config.showsCursor = showCursor
        config.captureResolution = .best
        config.colorSpaceName = CGColorSpace.sRGB
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return Captured(image: image, scale: scale)
    }

    /// Captures a single window independently of what covers it, optionally with its shadow.
    static func captureWindow(_ windowID: CGWindowID, shadow: Bool) async throws -> Captured {
        let content = try await content()
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else { throw CaptureError.noWindow }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)
        let size = filter.contentRect.size

        let config = SCStreamConfiguration()
        config.width = max(1, Int((size.width * scale).rounded()))
        config.height = max(1, Int((size.height * scale).rounded()))
        config.ignoreShadowsSingleWindow = !shadow
        config.showsCursor = false
        config.captureResolution = .best
        config.colorSpaceName = CGColorSpace.sRGB
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return Captured(image: image, scale: scale)
    }

    /// The desktop picture only (everything below the desktop icons).
    static func captureWallpaper(for screen: NSScreen) async -> CGImage? {
        guard let content = try? await content(),
              let display = content.displays.first(where: { $0.displayID == screen.displayID }) else { return nil }
        let iconLevel = Int(CGWindowLevelForKey(.desktopIconWindow))
        let wallpaper = content.windows.filter { $0.windowLayer < iconLevel && $0.frame.intersects(display.frame) }
        guard !wallpaper.isEmpty else { return nil }
        let filter = SCContentFilter(display: display, including: wallpaper)
        let scale = CGFloat(filter.pointPixelScale)
        let config = SCStreamConfiguration()
        config.width = Int(CGFloat(display.width) * scale)
        config.height = Int(CGFloat(display.height) * scale)
        config.showsCursor = false
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}

/// Visible application windows, front to back, for window-picking mode.
enum WindowList {
    struct Info {
        let id: CGWindowID
        /// Cocoa global coordinates.
        let frame: CGRect
        let ownerName: String
    }

    static func onScreen() -> [Info] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        let pid = ProcessInfo.processInfo.processIdentifier
        return list.compactMap { d in
            guard (d[kCGWindowLayer as String] as? Int) == 0,
                  (d[kCGWindowOwnerPID as String] as? pid_t) != pid,
                  let id = d[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDict = d[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width > 20, bounds.height > 20 else { return nil }
            if let alpha = d[kCGWindowAlpha as String] as? Double, alpha < 0.05 { return nil }
            return Info(id: id, frame: cocoaRect(fromQuartz: bounds), ownerName: d[kCGWindowOwnerName as String] as? String ?? "")
        }
    }
}
