import AppKit

enum OverlayMode {
    case area, window, allInOne
}

enum AllInOneAction: CaseIterable {
    case screenshot, pin, text, scrolling, recordVideo, recordGIF

    var title: String {
        switch self {
        case .screenshot: return "Capture"
        case .pin: return "Pin"
        case .text: return "Text"
        case .scrolling: return "Scroll"
        case .recordVideo: return "Record"
        case .recordGIF: return "GIF"
        }
    }

    var symbol: String {
        switch self {
        case .screenshot: return "camera"
        case .pin: return "pin"
        case .text: return "text.viewfinder"
        case .scrolling: return "arrow.up.and.down.text.horizontal"
        case .recordVideo: return "record.circle"
        case .recordGIF: return "photo.stack"
        }
    }
}

struct OverlaySelection {
    let screen: NSScreen
    /// Screen-local points, top-left origin.
    let localRect: CGRect
    var windowID: CGWindowID?
    var frozenImage: CGImage?
    var action: AllInOneAction = .screenshot
    var isFullscreen = false

    var globalRect: CGRect { screen.globalRect(fromLocalTopLeft: localRect) }

    /// The selection cut out of the frozen screen image.
    func croppedFrozen() -> Captured? {
        guard let image = frozenImage else { return nil }
        let s = CGFloat(image.width) / screen.frame.width
        let r = CGRect(x: localRect.minX * s, y: localRect.minY * s, width: localRect.width * s, height: localRect.height * s).integral
        return image.cropping(to: r).map { Captured(image: $0, scale: s) }
    }
}

/// Full-screen selection UI spanning every display: area drag, window picking (Space), magnifier,
/// crosshair, frozen screen, and the All-In-One action bar.
@MainActor
final class OverlaySession {
    private static var active: OverlaySession?

    private let mode: OverlayMode
    private var windowMode: Bool
    private let completion: (OverlaySelection?) -> Void
    private var windows: [OverlayWindow] = []
    fileprivate var frozen: [CGDirectDisplayID: CGImage] = [:]
    private var windowList: [WindowList.Info] = []

    // Shared state, Cocoa global coordinates.
    fileprivate var mouse: CGPoint = .zero
    fileprivate var dragStart: CGPoint?
    fileprivate var selection: CGRect?
    fileprivate var selectionScreen: NSScreen?
    fileprivate var hoveredWindow: WindowList.Info?
    fileprivate var selectedWindowID: CGWindowID?
    fileprivate var showsActionBar = false
    fileprivate var isWindowMode: Bool { windowMode }
    fileprivate var drawsFrozen: Bool { Prefs.freezeScreen }

    static var isActive: Bool { active != nil }

    static func begin(mode: OverlayMode, completion: @escaping (OverlaySelection?) -> Void) {
        guard active == nil else { return }
        let session = OverlaySession(mode: mode, completion: completion)
        active = session
        Task { await session.start() }
    }

    private init(mode: OverlayMode, completion: @escaping (OverlaySelection?) -> Void) {
        self.mode = mode
        self.windowMode = mode == .window
        self.completion = completion
    }

    private func start() async {
        if Prefs.freezeScreen || Prefs.showMagnifier {
            for screen in NSScreen.screens {
                frozen[screen.displayID] = try? await ScreenCapturer.captureScreen(screen).image
            }
        }
        windowList = WindowList.onScreen()
        mouse = NSEvent.mouseLocation
        for screen in NSScreen.screens {
            let window = OverlayWindow(session: self, screen: screen)
            windows.append(window)
            window.orderFrontRegardless()
        }
        // Like the system screenshot UI, take the keyboard without activating Cadre, so the app
        // being captured stays frontmost and keeps its focused window.
        (windows.first { NSMouseInRect(mouse, $0.frame, false) } ?? windows.first)?.makeKeyAndOrderFront(nil)
        NSCursor.crosshair.set()
        updateHover()
        redraw()
    }

    fileprivate func redraw() { windows.forEach { $0.contentView?.needsDisplay = true } }

    private func finish(_ result: OverlaySelection?) {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        NSCursor.arrow.set()
        Self.active = nil
        completion(result)
    }

    private func screen(containing p: CGPoint) -> NSScreen {
        NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.withMouse()
    }

    private func updateHover() {
        hoveredWindow = windowList.first { $0.frame.contains(mouse) }
    }

    // MARK: Events (forwarded by OverlayView)

    fileprivate func mouseMoved(to p: CGPoint) {
        mouse = p
        if dragStart == nil { updateHover() }
        redraw()
    }

    fileprivate func mouseDown(at p: CGPoint) {
        mouse = p
        dragStart = p
        selection = nil
        selectedWindowID = nil
        showsActionBar = false
        windows.forEach { $0.overlayView.removeActionBar() }
        selectionScreen = screen(containing: p)
        redraw()
    }

    fileprivate func mouseDragged(to p: CGPoint, square: Bool) {
        mouse = p
        guard let start = dragStart, !windowMode, let screen = selectionScreen else { return }
        var end = CGPoint(x: min(max(p.x, screen.frame.minX), screen.frame.maxX),
                          y: min(max(p.y, screen.frame.minY), screen.frame.maxY))
        if square {
            let side = max(abs(end.x - start.x), abs(end.y - start.y))
            end = CGPoint(x: start.x + (end.x >= start.x ? side : -side), y: start.y + (end.y >= start.y ? side : -side))
        }
        selection = CGRect(corner: start, end).integral
        redraw()
    }

    fileprivate func mouseUp(at p: CGPoint) {
        guard dragStart != nil else { return }
        dragStart = nil
        let screen = selectionScreen ?? self.screen(containing: p)

        if let rect = selection, rect.width >= 4, rect.height >= 4, !windowMode {
            if mode == .allInOne { presentActionBar(); return }
            finish(makeSelection(rect: rect, screen: screen))
            return
        }

        // A click: pick the window under the cursor, or the whole screen.
        selection = nil
        if let window = hoveredWindow {
            let windowScreen = self.screen(containing: window.frame.center)
            let rect = window.frame.intersection(windowScreen.frame)
            if mode == .allInOne {
                selection = rect
                selectionScreen = windowScreen
                selectedWindowID = window.id
                presentActionBar()
                return
            }
            var result = makeSelection(rect: rect, screen: windowScreen)
            result.windowID = window.id
            finish(result)
        } else if !windowMode {
            finishFullscreen(screen)
        }
    }

    fileprivate func keyDown(_ event: NSEvent) {
        switch Int(event.keyCode) {
        case 53: // Esc
            finish(nil)
        case 49: // Space
            guard dragStart == nil else { return }
            windowMode.toggle()
            selection = nil
            showsActionBar = false
            windows.forEach { $0.overlayView.removeActionBar() }
            updateHover()
            redraw()
        case 36, 76: // Return
            if let rect = selection, let screen = selectionScreen {
                var result = makeSelection(rect: rect, screen: screen)
                result.windowID = selectedWindowID
                finish(result)
            } else {
                finishFullscreen(screen(containing: mouse))
            }
        default:
            break
        }
    }

    private func finishFullscreen(_ screen: NSScreen) {
        var result = makeSelection(rect: screen.frame, screen: screen)
        result.isFullscreen = true
        finish(result)
    }

    private func makeSelection(rect: CGRect, screen: NSScreen) -> OverlaySelection {
        OverlaySelection(screen: screen, localRect: screen.localTopLeft(fromGlobal: rect),
                         frozenImage: frozen[screen.displayID])
    }

    private func presentActionBar() {
        guard let screen = selectionScreen,
              let window = windows.first(where: { $0.screen == screen }) else { return }
        showsActionBar = true
        window.overlayView.showActionBar()
        redraw()
    }

    fileprivate func choose(_ action: AllInOneAction) {
        guard let rect = selection, let screen = selectionScreen else { return }
        var result = makeSelection(rect: rect, screen: screen)
        result.action = action
        result.windowID = selectedWindowID
        finish(result)
    }
}

private final class OverlayWindow: NSPanel {
    let overlayView: OverlayView
    private let targetScreen: NSScreen

    init(session: OverlaySession, screen: NSScreen) {
        targetScreen = screen
        overlayView = OverlayView(session: session, screen: screen)
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        setFrame(screen.frame, display: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        contentView = overlayView
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override var screen: NSScreen? { targetScreen }
}

private final class OverlayView: NSView {
    private unowned let session: OverlaySession
    private let screen: NSScreen
    private var actionBar: NSView?

    init(session: OverlaySession, screen: NSScreen) {
        self.session = session
        self.screen = screen
        super.init(frame: CGRect(origin: .zero, size: screen.frame.size))
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.crosshair.set()
        session.mouseMoved(to: NSEvent.mouseLocation)
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        session.mouseDown(at: NSEvent.mouseLocation)
    }
    override func mouseDragged(with event: NSEvent) {
        session.mouseDragged(to: NSEvent.mouseLocation, square: event.modifierFlags.contains(.shift))
    }
    override func mouseUp(with event: NSEvent) { session.mouseUp(at: NSEvent.mouseLocation) }
    override func keyDown(with event: NSEvent) { session.keyDown(event) }
    override func rightMouseDown(with event: NSEvent) { session.keyDown(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!) }

    private func local(_ r: CGRect) -> CGRect { r.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY) }
    private func local(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x - screen.frame.minX, y: p.y - screen.frame.minY) }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let frozen = session.frozen[screen.displayID]
        if session.drawsFrozen, let frozen {
            ctx.draw(frozen, in: bounds)
        } else {
            ctx.clear(bounds)
        }

        let selection = session.selection.map(local)
        let dim = NSColor.black.withAlphaComponent(selection != nil ? 0.35 : 0.12)
        dim.setFill()
        if let sel = selection, sel.intersects(bounds) {
            let path = NSBezierPath(rect: bounds)
            path.appendRect(sel)
            path.windingRule = .evenOdd
            path.fill()
        } else {
            bounds.fill()
        }

        let mouseHere = NSMouseInRect(session.mouse, screen.frame, false)

        // Window highlight
        if session.dragStart == nil, session.selection == nil, let hovered = session.hoveredWindow,
           session.isWindowMode || hovered.frame.contains(session.mouse) {
            let r = local(hovered.frame)
            if r.intersects(bounds) {
                NSColor.controlAccentColor.withAlphaComponent(session.isWindowMode ? 0.25 : 0.08).setFill()
                r.fill()
                if session.isWindowMode {
                    NSColor.controlAccentColor.setStroke()
                    let p = NSBezierPath(rect: r.insetBy(dx: 1, dy: 1))
                    p.lineWidth = 2
                    p.stroke()
                    if mouseHere { drawLabel(hovered.ownerName.isEmpty ? "Window" : hovered.ownerName, at: CGPoint(x: r.midX, y: r.midY), centered: true) }
                }
            }
        }

        if let sel = selection {
            NSColor.white.setStroke()
            let border = NSBezierPath(rect: sel.insetBy(dx: -0.5, dy: -0.5))
            border.lineWidth = 1
            border.stroke()
            if session.dragStart != nil || session.showsActionBar {
                drawLabel("\(Int(sel.width)) × \(Int(sel.height))", at: CGPoint(x: sel.maxX - 4, y: sel.minY - 26), centered: false, alignRight: true)
            }
        }

        guard mouseHere, !session.showsActionBar else { return }
        let m = local(session.mouse)

        if Prefs.showCrosshair, !session.isWindowMode {
            NSColor.white.withAlphaComponent(0.6).setStroke()
            let lines = NSBezierPath()
            lines.move(to: CGPoint(x: m.x, y: 0)); lines.line(to: CGPoint(x: m.x, y: bounds.height))
            lines.move(to: CGPoint(x: 0, y: m.y)); lines.line(to: CGPoint(x: bounds.width, y: m.y))
            lines.lineWidth = 0.5
            lines.setLineDash([4, 4], count: 2, phase: 0)
            lines.stroke()
        }

        if Prefs.showMagnifier, !session.isWindowMode, let frozen {
            drawMagnifier(ctx: ctx, image: frozen, at: m)
        } else if session.dragStart == nil, !session.isWindowMode {
            drawLabel("\(Int(m.x)), \(Int(bounds.height - m.y))", at: CGPoint(x: m.x + 14, y: m.y - 30), centered: false)
        }
    }

    private func drawMagnifier(ctx: CGContext, image: CGImage, at m: CGPoint) {
        let size: CGFloat = 128
        let pixels = 15
        let s = CGFloat(image.width) / bounds.width
        let px = Int(m.x * s), py = Int((bounds.height - m.y) * s)
        let src = CGRect(x: px - pixels / 2, y: py - pixels / 2, width: pixels, height: pixels)

        var origin = CGPoint(x: m.x + 20, y: m.y - size - 20)
        if origin.x + size > bounds.width { origin.x = m.x - size - 20 }
        if origin.y < 0 { origin.y = m.y + 20 }
        let box = CGRect(origin: origin, size: CGSize(width: size, height: size))

        ctx.saveGState()
        let clip = NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8)
        NSColor.black.setFill()
        clip.fill()
        clip.addClip()
        ctx.interpolationQuality = .none
        if let crop = image.cropping(to: src) {
            // The crop may be clipped at image edges; keep pixels aligned with the cursor.
            let cell = size / CGFloat(pixels)
            let dx = CGFloat(crop.width) < CGFloat(pixels) && src.minX < 0 ? -src.minX * cell : 0
            let dyTop = CGFloat(crop.height) < CGFloat(pixels) && src.minY < 0 ? -src.minY * cell : 0
            ctx.draw(crop, in: CGRect(x: box.minX + dx, y: box.maxY - dyTop - CGFloat(crop.height) * cell,
                                      width: CGFloat(crop.width) * cell, height: CGFloat(crop.height) * cell))
        }
        let cell = size / CGFloat(pixels)
        let center = CGRect(x: box.minX + cell * CGFloat(pixels / 2), y: box.minY + cell * CGFloat(pixels / 2), width: cell, height: cell)
        NSColor.white.setStroke()
        NSBezierPath(rect: center).stroke()
        ctx.restoreGState()
        NSColor.white.withAlphaComponent(0.8).setStroke()
        let rim = NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8)
        rim.lineWidth = 1.5
        rim.stroke()

        let text: String
        if let sel = session.selection, session.dragStart != nil {
            text = "\(Int(sel.width)) × \(Int(sel.height))"
        } else {
            text = "\(Int(m.x)), \(Int(bounds.height - m.y))"
        }
        drawLabel(text, at: CGPoint(x: box.midX, y: box.minY - 24), centered: true)
    }

    private func drawLabel(_ text: String, at p: CGPoint, centered: Bool, alignRight: Bool = false) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let size = str.size()
        var rect = CGRect(x: p.x, y: p.y, width: size.width + 12, height: size.height + 6)
        if centered { rect.origin.x -= rect.width / 2 }
        if alignRight { rect.origin.x -= rect.width }
        rect.origin.x = max(4, min(rect.origin.x, bounds.width - rect.width - 4))
        rect.origin.y = max(4, min(rect.origin.y, bounds.height - rect.height - 4))
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
        str.draw(at: CGPoint(x: rect.minX + 6, y: rect.minY + 3))
    }

    // MARK: All-In-One action bar

    func showActionBar() {
        removeActionBar()
        guard let sel = session.selection.map(local) else { return }
        let buttons = AllInOneAction.allCases.map { action -> NSButton in
            let b = ActionButton(action: action) { [weak self] in self?.session.choose(action) }
            return b
        }
        let stack = NSStackView(views: buttons)
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        let bar = NSVisualEffectView()
        bar.material = .hudWindow
        bar.state = .active
        bar.appearance = NSAppearance(named: .vibrantDark)
        bar.wantsLayer = true
        bar.layer?.cornerRadius = 10
        bar.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            stack.topAnchor.constraint(equalTo: bar.topAnchor),
            stack.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
        ])
        let size = stack.fittingSize
        var origin = CGPoint(x: sel.midX - size.width / 2, y: sel.minY - size.height - 12)
        if origin.y < 8 { origin.y = sel.minY + 12 }
        origin.x = max(8, min(origin.x, bounds.width - size.width - 8))
        bar.frame = CGRect(origin: origin, size: size)
        addSubview(bar)
        actionBar = bar
    }

    func removeActionBar() {
        actionBar?.removeFromSuperview()
        actionBar = nil
    }
}

private final class ActionButton: NSButton {
    private let handler: () -> Void

    init(action: AllInOneAction, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        title = action.title
        image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: action.title)
        imagePosition = .imageAbove
        isBordered = false
        font = .systemFont(ofSize: 10, weight: .medium)
        contentTintColor = .white
        target = self
        self.action = #selector(fire)
        widthAnchor.constraint(equalToConstant: 54).isActive = true
        heightAnchor.constraint(equalToConstant: 42).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}
