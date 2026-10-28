import AppKit

/// Hides desktop icons by covering them with a window that shows the wallpaper,
/// sitting just above the icon layer and below every application window.
@MainActor
final class DesktopIconsHider {
    static let shared = DesktopIconsHider()

    private(set) var isHidden = false
    private var windows: [NSWindow] = []

    var windowIDs: Set<CGWindowID> { Set(windows.map { CGWindowID($0.windowNumber) }) }

    func toggle() {
        if isHidden { show() } else { Task { await hide() } }
    }

    func hide() async {
        guard !isHidden else { return }
        isHidden = true
        for screen in NSScreen.screens {
            var image = await ScreenCapturer.captureWallpaper(for: screen)
            if image == nil, let url = NSWorkspace.shared.desktopImageURL(for: screen) {
                image = NSImage(contentsOf: url)?.cgImage
            }
            let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.setFrame(screen.frame, display: false)
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            window.isReleasedWhenClosed = false
            window.hasShadow = false
            window.backgroundColor = .windowBackgroundColor
            window.contentView = AspectFillImageView(image: image)
            window.orderFront(nil)
            windows.append(window)
        }
        // Let the window server composite the cover before anyone captures.
        try? await Task.sleep(for: .milliseconds(120))
    }

    func show() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        isHidden = false
    }
}

final class AspectFillImageView: NSView {
    private let image: CGImage?

    init(image: CGImage?) {
        self.image = image
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard let image, let ctx = NSGraphicsContext.current?.cgContext else {
            NSColor.windowBackgroundColor.setFill()
            bounds.fill()
            return
        }
        let iw = CGFloat(image.width), ih = CGFloat(image.height)
        let s = max(bounds.width / iw, bounds.height / ih)
        let size = CGSize(width: iw * s, height: ih * s)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                                   width: size.width, height: size.height))
    }
}
