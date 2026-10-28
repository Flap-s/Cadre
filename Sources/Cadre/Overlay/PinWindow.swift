import AppKit
import UniformTypeIdentifiers

/// Screenshots pinned above all windows. Scroll or pinch to resize, right-click for options.
@MainActor
final class PinManager {
    static let shared = PinManager()

    private var pins: [PinWindow] = []

    var windowIDs: Set<CGWindowID> { Set(pins.map { CGWindowID($0.windowNumber) }) }
    var hasLockedPins: Bool { pins.contains { $0.isLocked } }

    func pin(image: CGImage, scale: CGFloat, frame: CGRect? = nil) {
        let window = PinWindow(image: image, scale: scale, frame: frame)
        pins.append(window)
        window.makeKeyAndOrderFront(nil)
    }

    func remove(_ window: PinWindow) {
        pins.removeAll { $0 === window }
        window.orderOut(nil)
    }

    func unlockAll() { pins.forEach { $0.isLocked = false } }
    func closeAll() { pins.forEach(remove) }
}

final class PinWindow: KeyPanel {
    let image: CGImage
    let scale: CGFloat

    var isLocked = false {
        didSet {
            ignoresMouseEvents = isLocked
            pinView.needsDisplay = true
        }
    }

    private var pinView: PinView { contentView as! PinView }

    @MainActor init(image: CGImage, scale: CGFloat, frame: CGRect?) {
        self.image = image
        self.scale = scale
        let screen = NSScreen.withMouse().visibleFrame
        var size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let fit = min(1, screen.width * 0.8 / size.width, screen.height * 0.8 / size.height)
        size = CGSize(width: size.width * fit, height: size.height * fit)
        let rect = frame ?? CGRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2,
                                   width: size.width, height: size.height)
        super.init(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = PinView(window: self)
    }

    @MainActor func zoom(by factor: CGFloat, around point: CGPoint) {
        let f = frame
        let width = min(max(f.width * factor, 40), 8000)
        let k = width / f.width
        let new = CGRect(x: point.x - (point.x - f.minX) * k, y: point.y - (point.y - f.minY) * k,
                         width: width, height: f.height * k)
        setFrame(new, display: true)
    }

    @MainActor func resetSize() {
        let size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        setFrame(CGRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2, width: size.width, height: size.height),
                 display: true)
    }
}

@MainActor
private final class PinView: NSView {
    private unowned let pin: PinWindow

    init(window: PinWindow) {
        pin = window
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.interpolationQuality = .high
        ctx.draw(pin.image, in: bounds)
        NSColor.white.withAlphaComponent(0.35).setStroke()
        let border = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 8
        pin.zoom(by: 1 + delta * 0.005, around: NSEvent.mouseLocation)
    }

    override func magnify(with event: NSEvent) {
        pin.zoom(by: 1 + event.magnification, around: NSEvent.mouseLocation)
    }

    override func mouseUp(with event: NSEvent) {
        if event.clickCount == 2 { pin.resetSize() }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { PinManager.shared.remove(pin); return }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "c" { copyImage(); return }
        super.keyDown(with: event)
    }

    @objc func copy(_ sender: Any?) { copyImage() }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy", action: #selector(copyMenu), keyEquivalent: "c").target = self
        menu.addItem(withTitle: "Save…", action: #selector(saveAs), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Annotate", action: #selector(annotate), keyEquivalent: "").target = self
        menu.addItem(.separator())
        let opacity = NSMenu()
        for value in [100, 75, 50, 25] {
            let item = NSMenuItem(title: "\(value)%", action: #selector(setOpacity(_:)), keyEquivalent: "")
            item.target = self
            item.tag = value
            item.state = Int((pin.alphaValue * 100).rounded()) == value ? .on : .off
            opacity.addItem(item)
        }
        menu.addItem(submenu: opacity, title: "Opacity")
        menu.addItem(withTitle: "Original Size", action: #selector(originalSize), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Lock (Click-Through)", action: #selector(lock), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Close", action: #selector(close), keyEquivalent: "").target = self
        return menu
    }

    private func copyImage() {
        Clipboard.copy(image: pin.image, scale: pin.scale)
        HUD.show("Copied to clipboard")
    }

    @objc private func copyMenu() { copyImage() }

    @objc private func saveAs() {
        NSApp.activate()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Prefs.imageFormat.utType]
        panel.nameFieldStringValue = FileNaming.name(prefix: "Screenshot", ext: Prefs.imageFormat.fileExtension)
        panel.directoryURL = Prefs.saveFolder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? pin.image.encoded(as: Prefs.imageFormat, scale: pin.scale)?.write(to: url)
    }

    @objc private func annotate() {
        AnnotationEditorController.open(CaptureItem(image: pin.image, scale: pin.scale))
    }

    @objc private func setOpacity(_ sender: NSMenuItem) { pin.alphaValue = CGFloat(sender.tag) / 100 }
    @objc private func originalSize() { pin.resetSize() }

    @objc private func lock() {
        pin.isLocked = true
        HUD.show("Pinned screenshot locked — unlock from the menu bar", symbol: "lock.fill", duration: 2.5)
    }

    @objc private func close() { PinManager.shared.remove(pin) }
}
