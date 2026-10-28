import AppKit
import ApplicationServices
import CoreGraphics
import ScreenCaptureKit

enum Permissions {
    static var hasScreenRecording: Bool { CGPreflightScreenCaptureAccess() }

    static func requestScreenRecording() {
        if !CGRequestScreenCaptureAccess() {
            openPrivacyPane("Privacy_ScreenCapture")
        }
    }

    /// Returns true when capturing can proceed. Otherwise asks for permission and explains what to do.
    @MainActor static func ensureScreenRecording() async -> Bool {
        if hasScreenRecording { return true }
        // CGPreflightScreenCaptureAccess can lag behind the real permission state (it is cached per
        // process); ScreenCaptureKit only hands out shareable content when capture is really allowed.
        if (try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)) != nil { return true }
        if CGRequestScreenCaptureAccess() { return true }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Screen Recording permission needed"
        alert.informativeText = "Enable Cadre in System Settings › Privacy & Security › Screen & System Audio Recording, then relaunch Cadre. If Cadre is already enabled there, remove it with the – button and add it again: the entry may belong to an older build."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { openPrivacyPane("Privacy_ScreenCapture") }
        return false
    }

    /// Needed for keystroke display and auto-scrolling.
    @discardableResult
    static func ensureAccessibility(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    static func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}

enum Sound {
    private static let systemDir = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/"
    private static var cache: [String: NSSound] = [:]

    private static func play(file: String, fallback: String) {
        guard Prefs.playSounds else { return }
        let sound = cache[file] ?? NSSound(contentsOfFile: systemDir + file, byReference: true) ?? NSSound(named: fallback)
        cache[file] = sound
        sound?.stop()
        sound?.play()
    }

    static func capture() { play(file: "Screen Capture.aif", fallback: "Tink") }
    static func startRecording() { play(file: "begin_record.caf", fallback: "Pop") }
    static func stopRecording() { play(file: "end_record.caf", fallback: "Pop") }
    static func tick() { play(file: "Media Keys.aif", fallback: "Tink") }
    static func done() { play(file: "SentMessage.caf", fallback: "Glass") }
}

/// Small transient message ("Copied", "Text copied"…).
@MainActor
enum HUD {
    private static var panel: NSPanel?
    private static var hideWork: DispatchWorkItem?

    static func show(_ text: String, symbol: String = "checkmark.circle.fill", duration: TimeInterval = 1.5) {
        panel?.orderOut(nil)
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = .labelColor
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 18, weight: .semibold)
        icon.contentTintColor = symbol.contains("xmark") || symbol.contains("exclamation") ? .systemRed : .systemGreen
        let stack = NSStackView(views: [icon, label])
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 18)

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            stack.topAnchor.constraint(equalTo: effect.topAnchor),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        let size = stack.fittingSize
        let screen = NSScreen.withMouse().visibleFrame
        let p = NSPanel(contentRect: NSRect(x: screen.midX - size.width / 2, y: screen.minY + 90,
                                            width: size.width, height: size.height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = effect
        p.orderFrontRegardless()
        panel = p

        hideWork?.cancel()
        let work = DispatchWorkItem {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; p.animator().alphaValue = 0 },
                                                 completionHandler: { p.orderOut(nil) })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    static func error(_ text: String) { show(text, symbol: "exclamationmark.triangle.fill", duration: 2.5) }
}

/// Big "3, 2, 1" countdown used by the self-timer and before recordings.
@MainActor
enum Countdown {
    static func run(seconds: Int, on screen: NSScreen, centeredIn rect: CGRect? = nil) async {
        let frame = rect ?? screen.frame
        let size: CGFloat = 140
        let panel = NSPanel(contentRect: NSRect(x: frame.midX - size / 2, y: frame.midY - size / 2, width: size, height: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = size / 2
        let label = NSTextField(labelWithString: "")
        label.font = .monospacedDigitSystemFont(ofSize: 72, weight: .bold)
        label.alignment = .center
        label.frame = NSRect(x: 0, y: (size - 90) / 2, width: size, height: 90)
        effect.addSubview(label)
        panel.contentView = effect
        panel.orderFrontRegardless()

        for n in stride(from: seconds, to: 0, by: -1) {
            label.stringValue = "\(n)"
            Sound.tick()
            try? await Task.sleep(for: .seconds(1))
        }
        panel.orderOut(nil)
        // Give the window server a moment so the countdown never ends up in the capture.
        try? await Task.sleep(for: .milliseconds(80))
    }
}

/// A click-through frame drawn around a region (recording / scrolling capture).
final class BorderWindow: NSWindow {
    init(around rect: CGRect, color: NSColor = .systemRed, dashed: Bool = false) {
        let inset: CGFloat = 3
        super.init(contentRect: rect.insetBy(dx: -inset, dy: -inset), styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        ignoresMouseEvents = true
        hasShadow = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        contentView = BorderView(color: color, dashed: dashed, inset: inset)
    }

    private final class BorderView: NSView {
        let color: NSColor, dashed: Bool, inset: CGFloat
        init(color: NSColor, dashed: Bool, inset: CGFloat) {
            self.color = color; self.dashed = dashed; self.inset = inset
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath(rect: bounds.insetBy(dx: inset / 2, dy: inset / 2))
            path.lineWidth = 2
            if dashed { path.setLineDash([6, 4], count: 2, phase: 0) }
            color.setStroke()
            path.stroke()
        }
    }
}
