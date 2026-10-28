import AppKit

/// Scrolling capture: the user (or auto-scroll) scrolls the content inside the selected region
/// while frames are captured and stitched.
@MainActor
final class ScrollingCaptureSession {
    private static var current: ScrollingCaptureSession?
    static var isActive: Bool { current != nil }

    private let screen: NSScreen
    private let rect: CGRect // screen-local, top-left
    private let stitcher = ScrollStitcher()
    private var border: BorderWindow?
    private var panel: NSPanel?
    private var statusLabel: NSTextField!
    private var autoButton: NSButton!
    private var timer: Timer?
    private var busy = false
    private var autoScroll = false
    private var stillFrames = 0
    private var scale: CGFloat = 2

    static func start(screen: NSScreen, rect: CGRect) {
        guard current == nil else { return }
        let session = ScrollingCaptureSession(screen: screen, rect: rect)
        current = session
        session.begin()
    }

    private init(screen: NSScreen, rect: CGRect) {
        self.screen = screen
        self.rect = rect
    }

    private var globalRect: CGRect { screen.globalRect(fromLocalTopLeft: rect) }

    private func begin() {
        border = BorderWindow(around: globalRect, color: .controlAccentColor, dashed: true)
        border?.orderFrontRegardless()
        makePanel()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        tick()
    }

    private func makePanel() {
        statusLabel = NSTextField(labelWithString: "Scroll slowly to capture…")
        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.textColor = .white
        autoButton = NSButton(title: "Auto-scroll", target: self, action: #selector(toggleAuto))
        let done = NSButton(title: "Done", target: self, action: #selector(finish))
        done.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let stack = NSStackView(views: [statusLabel, autoButton, cancel, done])
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 10)

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
        let size = NSSize(width: max(stack.fittingSize.width, 420), height: stack.fittingSize.height)
        let g = globalRect
        var origin = CGPoint(x: g.midX - size.width / 2, y: g.minY - size.height - 12)
        if origin.y < screen.visibleFrame.minY { origin.y = g.maxY + 12 }
        if origin.y + size.height > screen.visibleFrame.maxY { origin.y = screen.visibleFrame.minY + 12 }
        origin.x = max(screen.frame.minX + 8, min(origin.x, screen.frame.maxX - size.width - 8))

        let p = KeyPanel(contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = effect
        p.orderFrontRegardless()
        panel = p
    }

    private func tick() {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            if autoScroll {
                postScroll()
                try? await Task.sleep(for: .milliseconds(180))
            }
            guard ScrollingCaptureSession.current === self,
                  let captured = try? await ScreenCapturer.captureScreen(screen, rect: rect) else { return }
            scale = captured.scale
            let result = stitcher.add(captured.image)
            switch result {
            case .first, .appended:
                stillFrames = 0
                statusLabel.stringValue = "\(Int(CGFloat(stitcher.totalHeight) / scale)) pt captured"
            case .noChange:
                stillFrames += 1
                if autoScroll && stillFrames >= 4 { finish() }
            case .noMatch:
                statusLabel.stringValue = "Scroll slower…"
            case .full:
                statusLabel.stringValue = "Maximum height reached"
                finish()
            case .sizeMismatch:
                break
            }
        }
    }

    private func postScroll() {
        let center = quartzPoint(fromCocoa: globalRect.center)
        let amount = Int32(max(40, rect.height * 0.35))
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                  wheel1: -amount, wheel2: 0, wheel3: 0) else { return }
        event.location = center
        event.post(tap: .cghidEventTap)
    }

    @objc private func toggleAuto() {
        if !autoScroll {
            guard Permissions.ensureAccessibility(prompt: true) else {
                HUD.error("Allow Cadre in Accessibility settings to auto-scroll")
                return
            }
            CGWarpMouseCursorPosition(quartzPoint(fromCocoa: globalRect.center))
        }
        autoScroll.toggle()
        stillFrames = 0
        autoButton.title = autoScroll ? "Stop" : "Auto-scroll"
    }

    @objc private func finish() {
        guard ScrollingCaptureSession.current === self else { return }
        let image = stitcher.makeImage()
        teardown()
        if let image {
            CaptureCoordinator.shared.deliver(Captured(image: image, scale: scale), prefix: "Scrolling Capture")
        }
    }

    @objc private func cancel() { teardown() }

    private func teardown() {
        timer?.invalidate()
        timer = nil
        border?.orderOut(nil)
        panel?.orderOut(nil)
        ScrollingCaptureSession.current = nil
    }
}

/// A non-activating panel that can still become key (for buttons and key equivalents).
class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
