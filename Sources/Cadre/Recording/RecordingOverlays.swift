import AppKit
@preconcurrency import AVFoundation

/// Floating timer + pause / stop / restart / delete buttons shown while recording.
final class RecordingControls: KeyPanel {
    private let timeLabel = NSTextField(labelWithString: "0:00")
    private var pauseButton: NSButton!

    @MainActor init(around region: CGRect, on screen: NSScreen) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let dot = NSImageView(image: NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)!)
        dot.contentTintColor = .systemRed
        dot.symbolConfiguration = .init(pointSize: 9, weight: .regular)
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        timeLabel.textColor = .white
        pauseButton = button("pause.fill", "Pause / Resume", #selector(pause))
        let stack = NSStackView(views: [
            dot, timeLabel,
            pauseButton,
            button("stop.fill", "Stop", #selector(stop), tint: .systemRed),
            button("arrow.counterclockwise", "Restart", #selector(restart)),
            button("trash", "Discard", #selector(discard)),
        ])
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 10)

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.appearance = NSAppearance(named: .vibrantDark)
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            stack.topAnchor.constraint(equalTo: effect.topAnchor),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        contentView = effect

        let size = stack.fittingSize
        let visible = screen.visibleFrame
        var origin = CGPoint(x: region.midX - size.width / 2, y: region.minY - size.height - 10)
        if origin.y < visible.minY { origin.y = visible.minY + 10 }
        origin.x = max(visible.minX + 8, min(origin.x, visible.maxX - size.width - 8))
        setFrame(CGRect(origin: origin, size: size), display: true)
    }

    private func button(_ symbol: String, _ tip: String, _ action: Selector, tint: NSColor = .white) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: self, action: action)
        b.isBordered = false
        b.contentTintColor = tint
        b.toolTip = tip
        return b
    }

    @MainActor func update(time: String, paused: Bool) {
        timeLabel.stringValue = time
        pauseButton.image = NSImage(systemSymbolName: paused ? "play.fill" : "pause.fill", accessibilityDescription: nil)
    }

    @objc private func pause() { Task { await ScreenRecorder.shared.togglePause() } }
    @objc private func stop() { Task { await ScreenRecorder.shared.stop() } }
    @objc private func restart() { Task { await ScreenRecorder.shared.restart() } }
    @objc private func discard() { Task { await ScreenRecorder.shared.cancel() } }
}

/// Round webcam bubble, visible in the recording.
final class CameraOverlay: NSPanel {
    private let session = AVCaptureSession()

    @MainActor init?(in region: CGRect) {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return nil }
        session.addInput(input)
        let size: CGFloat = min(200, max(120, region.width * 0.18))
        super.init(contentRect: CGRect(x: region.minX + 20, y: region.minY + 20, width: size, height: size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let view = NSView(frame: CGRect(x: 0, y: 0, width: size, height: size))
        view.wantsLayer = true
        view.layer?.cornerRadius = size / 2
        view.layer?.masksToBounds = true
        view.layer?.borderWidth = 3
        view.layer?.borderColor = NSColor.white.cgColor
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        if let connection = preview.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
        view.layer?.addSublayer(preview)
        contentView = view

        let session = self.session
        DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
    }

    @MainActor func stop() {
        let session = self.session
        DispatchQueue.global(qos: .userInitiated).async { session.stopRunning() }
        orderOut(nil)
    }
}

/// Shows pressed keys (⌘⇧4, ⌫…) at the bottom of the recorded region.
final class KeystrokeOverlay: NSPanel {
    private let label = NSTextField(labelWithString: "")
    private var monitor: Any?
    private var hideWork: DispatchWorkItem?
    private let region: CGRect

    @MainActor init(in region: CGRect) {
        self.region = region
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
        box.layer?.cornerRadius = 10
        label.font = .systemFont(ofSize: 26, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: box.centerYAnchor),
        ])
        contentView = box
        alphaValue = 0

        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let text = KeyNames.modifierSymbols(event.modifierFlags) + KeyNames.name(UInt32(event.keyCode))
            DispatchQueue.main.async { self?.show(text) }
        }
    }

    @MainActor private func show(_ text: String) {
        label.stringValue = text
        let size = CGSize(width: label.intrinsicContentSize.width + 36, height: 52)
        setFrame(CGRect(x: region.midX - size.width / 2, y: region.minY + 40, width: size.width, height: size.height), display: true)
        alphaValue = 1
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                self?.animator().alphaValue = 0
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    @MainActor func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        orderOut(nil)
    }
}
