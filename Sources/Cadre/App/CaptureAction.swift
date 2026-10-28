import AppKit
import Carbon

/// Every user-triggerable command: menu bar items, global shortcuts and the `cadre://` URL scheme.
enum CaptureAction: String, CaseIterable, Identifiable {
    case allInOne
    case captureArea
    case capturePreviousArea
    case captureFullscreen
    case captureWindow
    case selfTimer
    case scrollingCapture
    case captureText
    case pinArea
    case recordScreen
    case recordGIF
    case toggleDesktopIcons
    case annotateClipboard
    case openHistory
    case closeAllOverlays

    var id: String { rawValue }

    var title: String {
        switch self {
        case .allInOne: return "All-In-One"
        case .captureArea: return "Capture Area"
        case .capturePreviousArea: return "Capture Previous Area"
        case .captureFullscreen: return "Capture Fullscreen"
        case .captureWindow: return "Capture Window"
        case .selfTimer: return "Self-Timer"
        case .scrollingCapture: return "Scrolling Capture"
        case .captureText: return "Capture Text (OCR)"
        case .pinArea: return "Capture Area & Pin"
        case .recordScreen: return "Record Screen"
        case .recordGIF: return "Record GIF"
        case .toggleDesktopIcons: return "Hide / Show Desktop Icons"
        case .annotateClipboard: return "Annotate Clipboard Image"
        case .openHistory: return "Capture History"
        case .closeAllOverlays: return "Close All Overlays"
        }
    }

    var symbol: String {
        switch self {
        case .allInOne: return "square.grid.2x2"
        case .captureArea: return "viewfinder"
        case .capturePreviousArea: return "arrow.uturn.backward.square"
        case .captureFullscreen: return "display"
        case .captureWindow: return "macwindow"
        case .selfTimer: return "timer"
        case .scrollingCapture: return "arrow.up.and.down.text.horizontal"
        case .captureText: return "text.viewfinder"
        case .pinArea: return "pin"
        case .recordScreen: return "record.circle"
        case .recordGIF: return "photo.stack"
        case .toggleDesktopIcons: return "eye.slash"
        case .annotateClipboard: return "pencil.and.outline"
        case .openHistory: return "clock.arrow.circlepath"
        case .closeAllOverlays: return "xmark.square"
        }
    }

    /// URL scheme path, e.g. `cadre://capture-area`.
    var urlName: String {
        var result = ""
        var previousWasLower = false
        for c in rawValue {
            if c.isUppercase && previousWasLower { result += "-" }
            result += c.lowercased()
            previousWasLower = c.isLowercase
        }
        return result
    }

    var defaultCombo: KeyCombo? {
        let os: NSEvent.ModifierFlags = [.option, .shift]
        switch self {
        case .captureFullscreen: return KeyCombo(kVK_ANSI_3, os)
        case .captureArea: return KeyCombo(kVK_ANSI_4, os)
        case .allInOne: return KeyCombo(kVK_ANSI_5, os)
        case .captureWindow: return KeyCombo(kVK_ANSI_6, os)
        case .capturePreviousArea: return KeyCombo(kVK_ANSI_7, os)
        case .scrollingCapture: return KeyCombo(kVK_ANSI_S, os)
        case .captureText: return KeyCombo(kVK_ANSI_O, os)
        case .selfTimer: return KeyCombo(kVK_ANSI_T, os)
        case .pinArea: return KeyCombo(kVK_ANSI_P, os)
        case .recordScreen: return KeyCombo(kVK_ANSI_R, os)
        case .recordGIF: return KeyCombo(kVK_ANSI_G, os)
        case .toggleDesktopIcons: return KeyCombo(kVK_ANSI_D, os)
        case .openHistory: return KeyCombo(kVK_ANSI_H, os)
        case .annotateClipboard, .closeAllOverlays: return nil
        }
    }

    @MainActor func run() {
        let capture = CaptureCoordinator.shared
        switch self {
        case .allInOne: capture.allInOne()
        case .captureArea: capture.captureArea()
        case .capturePreviousArea: capture.capturePreviousArea()
        case .captureFullscreen: capture.captureFullscreen()
        case .captureWindow: capture.captureWindow()
        case .selfTimer: capture.selfTimer()
        case .scrollingCapture: capture.scrollingCapture()
        case .captureText: capture.captureText()
        case .pinArea: capture.captureAndPin()
        case .recordScreen: capture.record(gif: false)
        case .recordGIF: capture.record(gif: true)
        case .toggleDesktopIcons: DesktopIconsHider.shared.toggle()
        case .annotateClipboard: capture.annotateClipboard()
        case .openHistory: HistoryWindowController.show()
        case .closeAllOverlays:
            QuickAccessManager.shared.closeAll()
            PinManager.shared.closeAll()
        }
    }
}
