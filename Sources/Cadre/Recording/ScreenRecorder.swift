import AppKit
import AVFoundation
import ScreenCaptureKit

extension Notification.Name {
    static let recorderStateChanged = Notification.Name("CadreRecorderStateChanged")
}

/// Screen recording with ScreenCaptureKit's file output. Pausing closes the current segment;
/// segments are joined when the recording stops.
@MainActor
final class ScreenRecorder: NSObject {
    static let shared = ScreenRecorder()

    enum State { case idle, starting, recording, paused, finishing }

    private(set) var state: State = .idle { didSet { notify() } }
    var isActive: Bool { state != .idle }
    var isPaused: Bool { state == .paused }

    private var stream: SCStream?
    private var output: SCRecordingOutput?
    private var segments: [URL] = []
    private var finishContinuation: CheckedContinuation<Void, Never>?
    private let sink = NullStreamOutput()
    private let sinkQueue = DispatchQueue(label: "cadre.recorder.sink")

    private var selection: OverlaySelection?
    private var gif = false
    private var segmentStart: Date?
    private var accumulated: TimeInterval = 0
    private var ticker: Timer?

    private var border: BorderWindow?
    private var controls: RecordingControls?
    private var camera: CameraOverlay?
    private var keystrokes: KeystrokeOverlay?

    var overlayWindowIDs: Set<CGWindowID> {
        Set([camera, keystrokes].compactMap { $0.map { CGWindowID($0.windowNumber) } })
    }

    var elapsed: TimeInterval { accumulated + (segmentStart.map { Date().timeIntervalSince($0) } ?? 0) }

    var elapsedString: String {
        let t = Int(elapsed)
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    private func notify() { NotificationCenter.default.post(name: .recorderStateChanged, object: self) }

    // MARK: Start

    func start(selection sel: OverlaySelection, gif: Bool) async {
        guard state == .idle else { return }
        state = .starting
        selection = sel
        self.gif = gif
        segments = []
        accumulated = 0
        let region = sel.isFullscreen ? sel.screen.frame : sel.globalRect

        if Prefs.recMicrophone && !gif { _ = await AVCaptureDevice.requestAccess(for: .audio) }
        if Prefs.recCamera && !gif, await AVCaptureDevice.requestAccess(for: .video) {
            camera = CameraOverlay(in: region)
            camera?.orderFrontRegardless()
        }
        if Prefs.recKeystrokes, Permissions.ensureAccessibility(prompt: true) {
            keystrokes = KeystrokeOverlay(in: region)
            keystrokes?.orderFrontRegardless()
        }
        if !sel.isFullscreen {
            border = BorderWindow(around: region)
            border?.orderFrontRegardless()
        }
        if Prefs.recCountdown {
            await Countdown.run(seconds: 3, on: sel.screen, centeredIn: region)
        }

        do {
            try await startStream(sel)
            try await beginSegment()
            Sound.startRecording()
            state = .recording
            controls = RecordingControls(around: region, on: sel.screen)
            controls?.orderFrontRegardless()
            ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.controls?.update(time: self.elapsedString, paused: self.isPaused)
                    self.notify()
                }
            }
        } catch {
            HUD.error("Recording failed: \(error.localizedDescription)")
            await teardown()
            state = .idle
        }
    }

    private func startStream(_ sel: OverlaySelection) async throws {
        let content = try await ScreenCapturer.content()
        guard let display = content.displays.first(where: { $0.displayID == sel.screen.displayID }) else {
            throw CaptureError.noDisplay
        }
        let filter = ScreenCapturer.filter(display: display, content: content, keeping: OwnWindows.capturable)
        let scale = CGFloat(filter.pointPixelScale)
        let region = sel.isFullscreen ? CGRect(origin: .zero, size: sel.screen.frame.size) : sel.localRect

        let config = SCStreamConfiguration()
        if !sel.isFullscreen { config.sourceRect = region }
        // H.264/HEVC need even dimensions.
        config.width = max(2, Int(region.width * scale) / 2 * 2)
        config.height = max(2, Int(region.height * scale) / 2 * 2)
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(gif ? min(Prefs.recFPS, 30) : Prefs.recFPS))
        config.showsCursor = Prefs.recShowCursor
        config.showMouseClicks = Prefs.recShowClicks
        config.queueDepth = 6
        config.colorSpaceName = CGColorSpace.sRGB
        if !gif {
            config.capturesAudio = Prefs.recSystemAudio
            config.excludesCurrentProcessAudio = true
            config.sampleRate = 48_000
            config.channelCount = 2
            config.captureMicrophone = Prefs.recMicrophone
        }

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: sinkQueue)
        if config.capturesAudio { try stream.addStreamOutput(sink, type: .audio, sampleHandlerQueue: sinkQueue) }
        if config.captureMicrophone { try stream.addStreamOutput(sink, type: .microphone, sampleHandlerQueue: sinkQueue) }
        try await stream.startCapture()
        self.stream = stream
    }

    private func beginSegment() async throws {
        guard let stream else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Cadre", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("segment-\(UUID().uuidString).mp4")

        let config = SCRecordingOutputConfiguration()
        config.outputURL = url
        config.outputFileType = .mp4
        config.videoCodecType = Prefs.recUsesHEVC && !gif ? .hevc : .h264
        let output = SCRecordingOutput(configuration: config, delegate: self)
        try stream.addRecordingOutput(output)
        self.output = output
        segments.append(url)
        segmentStart = Date()
    }

    private func endSegment() async {
        guard let stream, let output else { return }
        self.output = nil
        if let start = segmentStart { accumulated += Date().timeIntervalSince(start) }
        segmentStart = nil
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            finishContinuation = c
            do {
                try stream.removeRecordingOutput(output)
            } catch {
                finishContinuation = nil
                c.resume()
            }
            // Never hang if the delegate callback doesn't arrive.
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                MainActor.assumeIsolated { self?.resumeFinish() }
            }
        }
    }

    fileprivate func resumeFinish() {
        finishContinuation?.resume()
        finishContinuation = nil
    }

    // MARK: Controls

    func togglePause() async {
        switch state {
        case .recording:
            await endSegment()
            state = .paused
        case .paused:
            do {
                try await beginSegment()
                state = .recording
            } catch {
                HUD.error(error.localizedDescription)
            }
        default:
            return
        }
        controls?.update(time: elapsedString, paused: isPaused)
    }

    func stop() async {
        guard state == .recording || state == .paused else { return }
        state = .finishing
        await endSegment()
        Sound.stopRecording()
        await teardown()
        let parts = segments
        segments = []
        do {
            var url = try await Self.join(parts)
            if gif {
                let gifURL = url.deletingPathExtension().appendingPathExtension("gif")
                try await GIFExporter.export(video: url, to: gifURL, fps: Prefs.gifFPS, maxWidth: Prefs.gifMaxWidth)
                try? FileManager.default.removeItem(at: url)
                url = gifURL
            }
            state = .idle
            CaptureCoordinator.shared.deliverVideo(at: url)
        } catch {
            state = .idle
            HUD.error("Couldn't finish the recording: \(error.localizedDescription)")
        }
    }

    func cancel() async {
        guard state == .recording || state == .paused else { return }
        state = .finishing
        await endSegment()
        await teardown()
        segments.forEach { try? FileManager.default.removeItem(at: $0) }
        segments = []
        state = .idle
    }

    func restart() async {
        guard let sel = selection else { return }
        let wasGIF = gif
        await cancel()
        await start(selection: sel, gif: wasGIF)
    }

    private func teardown() async {
        ticker?.invalidate()
        ticker = nil
        if let stream { try? await stream.stopCapture() }
        stream = nil
        output = nil
        segmentStart = nil
        border?.orderOut(nil); border = nil
        controls?.orderOut(nil); controls = nil
        camera?.stop(); camera = nil
        keystrokes?.stop(); keystrokes = nil
        if Prefs.hideDesktopIconsWhileCapturing { DesktopIconsHider.shared.show() }
    }

    /// Concatenates pause segments into one file.
    private static func join(_ parts: [URL]) async throws -> URL {
        var valid: [AVURLAsset] = []
        for url in parts where FileManager.default.fileExists(atPath: url.path) {
            let asset = AVURLAsset(url: url)
            if let duration = try? await asset.load(.duration), duration.seconds > 0 { valid.append(asset) }
        }
        guard !valid.isEmpty else { throw CocoaError(.fileNoSuchFile) }
        if valid.count == 1 { return valid[0].url }

        let composition = AVMutableComposition()
        for asset in valid {
            let duration = try await asset.load(.duration)
            try await composition.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: asset, at: composition.duration)
        }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("Cadre/joined-\(UUID().uuidString).mp4")
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw CocoaError(.featureUnsupported)
        }
        try await session.export(to: out, as: .mp4)
        valid.forEach { try? FileManager.default.removeItem(at: $0.url) }
        return out
    }
}

extension ScreenRecorder: SCStreamDelegate, SCRecordingOutputDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            // e.g. stopped from the system's screen-sharing menu.
            if self.state == .recording || self.state == .paused { await self.stop() }
        }
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in self.resumeFinish() }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        Task { @MainActor in
            NSLog("Cadre recording output failed: \(error.localizedDescription)")
            self.resumeFinish()
        }
    }
}

/// ScreenCaptureKit wants an output per captured type even when only the file output is used.
private final class NullStreamOutput: NSObject, SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {}
}

enum GIFExporter {
    static func export(video: URL, to output: URL, fps: Int, maxWidth: Int, range: CMTimeRange? = nil) async throws {
        let asset = AVURLAsset(url: video)
        let duration = try await asset.load(.duration)
        let timeRange = range ?? CMTimeRange(start: .zero, duration: duration)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 60)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 60)
        generator.maximumSize = CGSize(width: maxWidth, height: maxWidth * 4)

        let count = max(1, Int(timeRange.duration.seconds * Double(fps)))
        guard let dest = CGImageDestinationCreateWithURL(output as CFURL, "com.compuserve.gif" as CFString, count, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationSetProperties(dest, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)
        let delay = 1.0 / Double(fps)
        let frameProps = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay],
        ] as CFDictionary
        for i in 0..<count {
            let t = CMTimeAdd(timeRange.start, CMTime(seconds: Double(i) * delay, preferredTimescale: 600))
            let (image, _) = try await generator.image(at: t)
            CGImageDestinationAddImage(dest, image, frameProps)
        }
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }
}
