import AppKit

/// Floating thumbnails shown in a screen corner after each capture.
@MainActor
final class QuickAccessManager {
    static let shared = QuickAccessManager()

    private var panels: [QuickAccessPanel] = [] // newest first
    private var screen: NSScreen?

    func show(_ item: CaptureItem) {
        if panels.isEmpty { screen = NSScreen.withMouse() }
        let panel = QuickAccessPanel(item: item)
        panels.insert(panel, at: 0)
        layout(animated: true, newPanel: panel)
        panel.orderFrontRegardless()
    }

    func close(_ panel: QuickAccessPanel) {
        guard let index = panels.firstIndex(where: { $0 === panel }) else { return }
        panels.remove(at: index)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 0
        }, completionHandler: { panel.orderOut(nil) })
        layout(animated: true, newPanel: nil)
    }

    func closeAll() { panels.forEach(close) }

    private func layout(animated: Bool, newPanel: QuickAccessPanel?) {
        guard let visible = (screen ?? NSScreen.main)?.visibleFrame else { return }
        let margin: CGFloat = 18, spacing: CGFloat = 12
        var y = visible.minY + margin
        var overflow: [QuickAccessPanel] = []
        for panel in panels {
            let size = panel.frame.size
            if y + size.height > visible.maxY - margin { overflow.append(panel); continue }
            let x = Prefs.overlayOnRight ? visible.maxX - size.width - margin : visible.minX + margin
            let frame = NSRect(x: x, y: y, width: size.width, height: size.height)
            if panel === newPanel {
                // Slide in from the screen edge.
                let offset = Prefs.overlayOnRight ? size.width + margin : -(size.width + margin)
                panel.setFrame(frame.offsetBy(dx: offset, dy: 0), display: false)
                panel.alphaValue = 0
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.25
                    panel.animator().setFrame(frame, display: true)
                    panel.animator().alphaValue = 1
                }
            } else if animated {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.2
                    panel.animator().setFrame(frame, display: true)
                }
            } else {
                panel.setFrame(frame, display: true)
            }
            y += size.height + spacing
        }
        overflow.forEach(close)
    }
}

final class QuickAccessPanel: KeyPanel {
    let item: CaptureItem

    @MainActor init(item: CaptureItem) {
        self.item = item
        let width: CGFloat = 230
        let aspect = item.thumbnail.map { $0.size.height / max($0.size.width, 1) } ?? 0.6
        let size = NSSize(width: width, height: min(max(width * aspect, 110), 300))
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = QuickAccessCardView(item: item, panel: self)
    }
}

@MainActor
private final class QuickAccessCardView: NSView, NSDraggingSource {
    private let item: CaptureItem
    private weak var panel: QuickAccessPanel?
    private let imageView = NSImageView()
    private let hoverView = NSView()
    private var hovering = false
    private var mouseDownPoint: CGPoint?
    private var closeTimer: Timer?

    init(item: CaptureItem, panel: QuickAccessPanel) {
        self.item = item
        self.panel = panel
        super.init(frame: NSRect(origin: .zero, size: panel.frame.size))
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        imageView.image = item.thumbnail
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.frame = bounds
        imageView.autoresizingMask = [.width, .height]
        imageView.unregisterDraggedTypes()
        addSubview(imageView)

        if item.kind == .video {
            let badge = NSImageView(image: NSImage(systemSymbolName: "play.circle.fill", accessibilityDescription: nil)!)
            badge.symbolConfiguration = .init(pointSize: 30, weight: .regular)
            badge.contentTintColor = .white
            badge.frame = NSRect(x: bounds.midX - 18, y: bounds.midY - 18, width: 36, height: 36)
            badge.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
            addSubview(badge)
        }

        buildHoverControls()
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
        NotificationCenter.default.addObserver(self, selector: #selector(itemChanged), name: .captureItemChanged, object: item)
        scheduleAutoClose()
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func itemChanged() { imageView.image = item.thumbnail }

    private func buildHoverControls() {
        hoverView.frame = bounds
        hoverView.autoresizingMask = [.width, .height]
        hoverView.wantsLayer = true
        hoverView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        hoverView.isHidden = true
        addSubview(hoverView)

        let copy = pill("Copy", #selector(copyItem))
        let save = pill(item.savedURL == nil ? "Save" : "Show", #selector(saveItem))
        let stack = NSStackView(views: [copy, save])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        hoverView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: hoverView.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: hoverView.centerYAnchor),
        ])

        corner("xmark", #selector(closeCard), "Close", top: true, left: true)
        if item.kind == .image {
            corner("pin.fill", #selector(pinItem), "Pin", top: true, left: false)
            corner("pencil.tip.crop.circle", #selector(editItem), "Annotate", top: false, left: true)
        } else {
            corner("scissors", #selector(editItem), "Trim / Export", top: false, left: true)
        }
        corner("square.and.arrow.up", #selector(shareItem), "Share", top: false, left: false)
    }

    private func pill(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.controlSize = .large
        b.widthAnchor.constraint(equalToConstant: 96).isActive = true
        return b
    }

    private func corner(_ symbol: String, _ action: Selector, _ tip: String, top: Bool, left: Bool) {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: self, action: action)
        b.isBordered = false
        b.contentTintColor = .white
        b.toolTip = tip
        b.wantsLayer = true
        b.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        b.layer?.cornerRadius = 13
        let s: CGFloat = 26, m: CGFloat = 8
        b.frame = NSRect(x: left ? m : bounds.width - s - m, y: top ? bounds.height - s - m : m, width: s, height: s)
        b.autoresizingMask = [left ? .maxXMargin : .minXMargin, top ? .minYMargin : .maxYMargin]
        hoverView.addSubview(b)
    }

    // MARK: Hover & auto-close

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        hoverView.isHidden = false
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        hoverView.isHidden = true
        scheduleAutoClose()
    }

    private func scheduleAutoClose() {
        closeTimer?.invalidate()
        let seconds = Prefs.overlayAutoCloseSeconds
        guard seconds > 0 else { return }
        closeTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(seconds), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.hovering else { return }
                self.closeCard()
            }
        }
    }

    // MARK: Mouse: drag out, double-click

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint, start.distance(to: event.locationInWindow) > 4 else { return }
        mouseDownPoint = nil
        let dragItem = NSDraggingItem(pasteboardWriter: item.fileURL as NSURL)
        dragItem.setDraggingFrame(bounds, contents: item.thumbnail)
        beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        if event.clickCount == 2 { editItem() }
        mouseDownPoint = nil
    }

    nonisolated func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    nonisolated func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        guard operation != [] else { return }
        MainActor.assumeIsolated { closeCard() }
    }

    // MARK: Actions

    @objc private func copyItem() {
        item.copyToPasteboard()
        HUD.show("Copied to clipboard")
        closeCard()
    }

    @objc private func saveItem() {
        if item.savedURL != nil {
            item.revealInFinder()
        } else if item.save() != nil {
            HUD.show("Saved to \(Prefs.saveFolder.lastPathComponent)")
        }
        closeCard()
    }

    @objc private func pinItem() {
        guard let image = item.image else { return }
        PinManager.shared.pin(image: image, scale: item.scale)
        closeCard()
    }

    @objc private func editItem() {
        if item.kind == .image {
            AnnotationEditorController.open(item)
        } else {
            VideoEditorWindowController.open(item)
        }
        closeCard()
    }

    @objc private func shareItem(_ sender: NSButton) {
        NSSharingServicePicker(items: [item.fileURL]).show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }

    @objc private func closeCard() {
        closeTimer?.invalidate()
        if let panel { QuickAccessManager.shared.close(panel) }
    }
}
