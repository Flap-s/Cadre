import AppKit
import AVFoundation

extension Notification.Name {
    static let captureItemChanged = Notification.Name("CadreCaptureItemChanged")
}

/// A screenshot or recording produced by Cadre (or an image opened for annotation).
@MainActor
final class CaptureItem {
    enum Kind { case image, video }

    let id = UUID()
    let kind: Kind
    let date: Date
    private(set) var image: CGImage?
    let scale: CGFloat
    /// Always-present backing file (history copy or opened file) — used for drag & drop and sharing.
    private(set) var fileURL: URL
    /// Where the user saved it, if anywhere.
    private(set) var savedURL: URL?
    /// The file belongs to the user (opened from Finder) and must never be overwritten.
    let isExternal: Bool
    private(set) var thumbnail: NSImage?

    var nsImage: NSImage? { image?.nsImage(scale: scale) }
    var displayName: String { (savedURL ?? fileURL).lastPathComponent }

    /// A fresh screenshot: stored in the history right away.
    init(image: CGImage, scale: CGFloat, prefix: String = "Screenshot") {
        kind = .image
        date = Date()
        self.image = image
        self.scale = scale
        isExternal = false
        let name = FileNaming.name(prefix: prefix, ext: Prefs.imageFormat.fileExtension, date: date)
        fileURL = HistoryStore.shared.directory.appendingPathComponent(name)
        try? image.encoded(as: Prefs.imageFormat, scale: scale)?.write(to: fileURL)
        thumbnail = image.nsImage(scale: scale)
        HistoryStore.shared.add(url: fileURL, kind: .image, date: date)
    }

    /// An image file opened for annotation / pinning.
    init?(imageAt url: URL) {
        guard let loaded = CGImage.load(from: url) else { return nil }
        kind = .image
        date = Date()
        image = loaded.image
        scale = loaded.scale
        fileURL = url
        isExternal = !url.path.hasPrefix(HistoryStore.shared.directory.path)
        thumbnail = loaded.image.nsImage(scale: loaded.scale)
    }

    /// A recording. `temporary` files are moved into the history.
    init(videoAt url: URL, temporary: Bool) {
        kind = .video
        date = Date()
        scale = 1
        isExternal = !temporary
        if temporary {
            let dest = FileNaming.unique(in: HistoryStore.shared.directory,
                                         name: FileNaming.name(prefix: "Recording", ext: url.pathExtension, date: date))
            if (try? FileManager.default.moveItem(at: url, to: dest)) != nil {
                fileURL = dest
                HistoryStore.shared.add(url: dest, kind: .video, date: date)
            } else {
                fileURL = url
            }
        } else {
            fileURL = url
        }
        thumbnail = Self.videoThumbnail(fileURL)
    }

    static func videoThumbnail(_ url: URL) -> NSImage? {
        if url.pathExtension.lowercased() == "gif" { return NSImage(contentsOf: url) }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 800, height: 800)
        guard let cg = try? generator.copyCGImage(at: .zero, actualTime: nil) else { return nil }
        return NSImage(cgImage: cg, size: CGSize(width: cg.width, height: cg.height))
    }

    // MARK: Actions

    func copyToPasteboard() {
        if kind == .image, let image {
            Clipboard.copy(image: image, scale: scale)
        } else {
            Clipboard.copy(fileURL: fileURL)
        }
    }

    /// Saves into the configured folder (once); returns the saved location.
    @discardableResult
    func save() -> URL? {
        if let savedURL, FileManager.default.fileExists(atPath: savedURL.path) { return savedURL }
        let folder = Prefs.saveFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dest = FileNaming.unique(in: folder, name: isExternal ? FileNaming.name(prefix: "Screenshot", ext: fileURL.pathExtension) : fileURL.lastPathComponent)
        do {
            if kind == .image, let image, let data = image.encoded(as: Prefs.imageFormat, scale: scale) {
                let url = dest.deletingPathExtension().appendingPathExtension(Prefs.imageFormat.fileExtension)
                try data.write(to: url)
                savedURL = url
            } else {
                try FileManager.default.copyItem(at: fileURL, to: dest)
                savedURL = dest
            }
            return savedURL
        } catch {
            HUD.error("Couldn't save: \(error.localizedDescription)")
            return nil
        }
    }

    /// Replace the image after annotating; keeps the history copy and the saved copy in sync.
    func update(image newImage: CGImage) {
        guard kind == .image else { return }
        image = newImage
        thumbnail = newImage.nsImage(scale: scale)
        if !isExternal {
            try? newImage.encoded(as: Prefs.imageFormat, scale: scale)?.write(to: fileURL)
        }
        if let savedURL {
            let format = ImageFormat.allCases.first { $0.fileExtension == savedURL.pathExtension.lowercased() } ?? .png
            try? newImage.encoded(as: format, scale: scale)?.write(to: savedURL)
        }
        NotificationCenter.default.post(name: .captureItemChanged, object: self)
    }

    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([savedURL ?? fileURL])
    }
}
