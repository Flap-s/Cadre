import AppKit
import UniformTypeIdentifiers

enum ImageFormat: String, CaseIterable, Identifiable {
    case png, jpeg, heic
    var id: String { rawValue }
    var utType: UTType {
        switch self {
        case .png: return .png
        case .jpeg: return .jpeg
        case .heic: return .heic
        }
    }
    var fileExtension: String {
        switch self {
        case .png: return "png"
        case .jpeg: return "jpg"
        case .heic: return "heic"
        }
    }
    var title: String { rawValue.uppercased() }
}

enum VideoFormat: String, CaseIterable, Identifiable {
    case mp4, gif
    var id: String { rawValue }
}

/// Keys shared by `Prefs` and the SwiftUI settings (`@AppStorage`).
enum PrefKey {
    static let playSounds = "playSounds"
    static let saveFolder = "saveFolder"
    static let imageFormat = "imageFormat"
    static let jpegQuality = "jpegQuality"
    static let downscaleRetina = "downscaleRetina"
    static let afterCaptureShowOverlay = "afterCaptureShowOverlay"
    static let afterCaptureCopy = "afterCaptureCopy"
    static let afterCaptureSave = "afterCaptureSave"
    static let afterCaptureOpenEditor = "afterCaptureOpenEditor"
    static let freezeScreen = "freezeScreen"
    static let showMagnifier = "showMagnifier"
    static let showCrosshair = "showCrosshair"
    static let captureCursor = "captureCursor"
    static let windowShadow = "windowShadow"
    static let hideDesktopIconsWhileCapturing = "hideDesktopIconsWhileCapturing"
    static let selfTimerSeconds = "selfTimerSeconds"
    static let overlayOnRight = "overlayOnRight"
    static let overlayAutoCloseSeconds = "overlayAutoCloseSeconds"
    static let recFPS = "recFPS"
    static let recCodec = "recCodec"
    static let recSystemAudio = "recSystemAudio"
    static let recMicrophone = "recMicrophone"
    static let recShowCursor = "recShowCursor"
    static let recShowClicks = "recShowClicks"
    static let recKeystrokes = "recKeystrokes"
    static let recCamera = "recCamera"
    static let recCountdown = "recCountdown"
    static let gifFPS = "gifFPS"
    static let gifMaxWidth = "gifMaxWidth"
    static let historyRetentionDays = "historyRetentionDays"
    static let onboarded = "onboarded"
    static let autoCheckUpdates = "autoCheckUpdates"
    static let lastUpdateCheck = "lastUpdateCheck"
    static let announcedUpdate = "announcedUpdate"
}

enum Prefs {
    private static var d: UserDefaults { .standard }

    static func registerDefaults() {
        d.register(defaults: [
            PrefKey.playSounds: true,
            PrefKey.saveFolder: "",
            PrefKey.imageFormat: ImageFormat.png.rawValue,
            PrefKey.jpegQuality: 0.9,
            PrefKey.downscaleRetina: false,
            PrefKey.afterCaptureShowOverlay: true,
            PrefKey.afterCaptureCopy: false,
            PrefKey.afterCaptureSave: true,
            PrefKey.afterCaptureOpenEditor: false,
            PrefKey.freezeScreen: false,
            PrefKey.showMagnifier: true,
            PrefKey.showCrosshair: true,
            PrefKey.captureCursor: false,
            PrefKey.windowShadow: true,
            PrefKey.hideDesktopIconsWhileCapturing: false,
            PrefKey.selfTimerSeconds: 5,
            PrefKey.overlayOnRight: false,
            PrefKey.overlayAutoCloseSeconds: 0,
            PrefKey.recFPS: 30,
            PrefKey.recCodec: "h264",
            PrefKey.recSystemAudio: false,
            PrefKey.recMicrophone: false,
            PrefKey.recShowCursor: true,
            PrefKey.recShowClicks: true,
            PrefKey.recKeystrokes: false,
            PrefKey.recCamera: false,
            PrefKey.recCountdown: true,
            PrefKey.gifFPS: 15,
            PrefKey.gifMaxWidth: 960,
            PrefKey.historyRetentionDays: 30,
            PrefKey.autoCheckUpdates: true,
        ])
    }

    static var playSounds: Bool { d.bool(forKey: PrefKey.playSounds) }
    static var saveFolder: URL {
        if let path = d.string(forKey: PrefKey.saveFolder), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    }
    static var imageFormat: ImageFormat { ImageFormat(rawValue: d.string(forKey: PrefKey.imageFormat) ?? "") ?? .png }
    static var jpegQuality: Double { d.double(forKey: PrefKey.jpegQuality) }
    static var downscaleRetina: Bool { d.bool(forKey: PrefKey.downscaleRetina) }
    static var afterCaptureShowOverlay: Bool { d.bool(forKey: PrefKey.afterCaptureShowOverlay) }
    static var afterCaptureCopy: Bool { d.bool(forKey: PrefKey.afterCaptureCopy) }
    static var afterCaptureSave: Bool { d.bool(forKey: PrefKey.afterCaptureSave) }
    static var afterCaptureOpenEditor: Bool { d.bool(forKey: PrefKey.afterCaptureOpenEditor) }
    static var freezeScreen: Bool { d.bool(forKey: PrefKey.freezeScreen) }
    static var showMagnifier: Bool { d.bool(forKey: PrefKey.showMagnifier) }
    static var showCrosshair: Bool { d.bool(forKey: PrefKey.showCrosshair) }
    static var captureCursor: Bool { d.bool(forKey: PrefKey.captureCursor) }
    static var windowShadow: Bool { d.bool(forKey: PrefKey.windowShadow) }
    static var hideDesktopIconsWhileCapturing: Bool { d.bool(forKey: PrefKey.hideDesktopIconsWhileCapturing) }
    static var selfTimerSeconds: Int { max(1, d.integer(forKey: PrefKey.selfTimerSeconds)) }
    static var overlayOnRight: Bool { d.bool(forKey: PrefKey.overlayOnRight) }
    static var overlayAutoCloseSeconds: Int { d.integer(forKey: PrefKey.overlayAutoCloseSeconds) }
    static var recFPS: Int { max(1, d.integer(forKey: PrefKey.recFPS)) }
    static var recUsesHEVC: Bool { d.string(forKey: PrefKey.recCodec) == "hevc" }
    static var recSystemAudio: Bool { d.bool(forKey: PrefKey.recSystemAudio) }
    static var recMicrophone: Bool { d.bool(forKey: PrefKey.recMicrophone) }
    static var recShowCursor: Bool { d.bool(forKey: PrefKey.recShowCursor) }
    static var recShowClicks: Bool { d.bool(forKey: PrefKey.recShowClicks) }
    static var recKeystrokes: Bool { d.bool(forKey: PrefKey.recKeystrokes) }
    static var recCamera: Bool { d.bool(forKey: PrefKey.recCamera) }
    static var recCountdown: Bool { d.bool(forKey: PrefKey.recCountdown) }
    static var gifFPS: Int { max(1, d.integer(forKey: PrefKey.gifFPS)) }
    static var gifMaxWidth: Int { max(100, d.integer(forKey: PrefKey.gifMaxWidth)) }
    static var historyRetentionDays: Int { d.integer(forKey: PrefKey.historyRetentionDays) }
    static var autoCheckUpdates: Bool { d.bool(forKey: PrefKey.autoCheckUpdates) }
}
