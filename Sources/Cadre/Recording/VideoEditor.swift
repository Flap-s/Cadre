import AppKit
import AVKit

/// Trim, mute and export (MP4 / GIF) a recording.
@MainActor
final class VideoEditorWindowController: NSWindowController, NSWindowDelegate {
    private static var open: [VideoEditorWindowController] = []

    private let item: CaptureItem
    private let playerView = AVPlayerView()
    private let muteCheckbox = NSButton(checkboxWithTitle: "Remove audio", target: nil, action: nil)
    private var isGIF: Bool { item.fileURL.pathExtension.lowercased() == "gif" }

    static func open(_ item: CaptureItem) {
        if item.fileURL.pathExtension.lowercased() == "gif" {
            NSWorkspace.shared.open(item.fileURL)
            return
        }
        let controller = VideoEditorWindowController(item: item)
        open.append(controller)
        AppPresence.windowOpened()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private init(item: CaptureItem) {
        self.item = item
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = item.displayName
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self

        playerView.player = AVPlayer(url: item.fileURL)
        playerView.controlsStyle = .floating
        playerView.showsSharingServiceButton = true

        let trim = NSButton(title: "Trim", image: NSImage(systemSymbolName: "timeline.selection", accessibilityDescription: nil)!,
                            target: self, action: #selector(trim))
        let mp4 = NSButton(title: "Export MP4…", target: self, action: #selector(exportMP4))
        let gif = NSButton(title: "Export GIF…", target: self, action: #selector(exportGIF))
        let copy = NSButton(title: "Copy", target: self, action: #selector(copyFile))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let bar = NSStackView(views: [trim, muteCheckbox, spacer, copy, gif, mp4])
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 10, right: 12)

        let content = NSView()
        for v in [playerView, bar] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            playerView.topAnchor.constraint(equalTo: content.topAnchor),
            playerView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            playerView.bottomAnchor.constraint(equalTo: bar.topAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func trim() {
        guard playerView.canBeginTrimming else { return }
        playerView.beginTrimming { _ in }
    }

    /// The trimmed range chosen in the player (or the whole asset).
    private func selectedRange() async -> CMTimeRange? {
        guard let playerItem = playerView.player?.currentItem else { return nil }
        let duration = (try? await playerItem.asset.load(.duration)) ?? playerItem.duration
        var start = playerItem.reversePlaybackEndTime
        var end = playerItem.forwardPlaybackEndTime
        if !start.isValid || start.isIndefinite { start = .zero }
        if !end.isValid || end.isIndefinite { end = duration }
        return CMTimeRange(start: start, end: end)
    }

    private func askDestination(ext: String) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = FileNaming.name(prefix: "Recording", ext: ext)
        panel.directoryURL = Prefs.saveFolder
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func exportVideo(to url: URL) async throws {
        let asset = AVURLAsset(url: item.fileURL)
        guard let range = await selectedRange() else { return }
        let composition = AVMutableComposition()
        for track in try await asset.load(.tracks) {
            if muteCheckbox.state == .on && track.mediaType == .audio { continue }
            guard let dest = composition.addMutableTrack(withMediaType: track.mediaType,
                                                         preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            try dest.insertTimeRange(range, of: track, at: .zero)
            dest.preferredTransform = try await track.load(.preferredTransform)
        }
        try? FileManager.default.removeItem(at: url)
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw CocoaError(.featureUnsupported)
        }
        try await session.export(to: url, as: .mp4)
    }

    @objc private func exportMP4() {
        guard let url = askDestination(ext: "mp4") else { return }
        Task {
            do {
                try await exportVideo(to: url)
                HUD.show("Exported \(url.lastPathComponent)")
            } catch {
                HUD.error(error.localizedDescription)
            }
        }
    }

    @objc private func exportGIF() {
        guard let url = askDestination(ext: "gif") else { return }
        Task {
            do {
                let range = await selectedRange()
                try await GIFExporter.export(video: item.fileURL, to: url, fps: Prefs.gifFPS, maxWidth: Prefs.gifMaxWidth, range: range)
                HUD.show("Exported \(url.lastPathComponent)")
            } catch {
                HUD.error(error.localizedDescription)
            }
        }
    }

    @objc private func copyFile() {
        item.copyToPasteboard()
        HUD.show("Copied to clipboard")
    }

    func windowWillClose(_ notification: Notification) {
        playerView.player?.pause()
        Self.open.removeAll { $0 === self }
        AppPresence.windowClosed()
    }
}
