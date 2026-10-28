import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The annotation editor window: tools, colors, background ("beautify"), and export actions.
@MainActor
final class AnnotationEditorController: NSWindowController, NSWindowDelegate {
    private static var open: [AnnotationEditorController] = []

    private let item: CaptureItem
    private let canvas: AnnotationCanvas
    private let toolControl = NSSegmentedControl()
    private let widthControl = NSSegmentedControl(labels: ["S", "M", "L"], trackingMode: .selectOne, target: nil, action: nil)
    private var swatches: [NSButton] = []
    private let colorWell = NSColorWell(style: .minimal)
    private var undoButton: NSButton!
    private var redoButton: NSButton!
    private let scrollView = NSScrollView()
    private let zoomLabel = NSTextField(labelWithString: "100%")
    private let backgroundModel = BackgroundModel()
    private var backgroundPopover: NSPopover?

    private static let palette: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue,
                                             .systemPurple, .white, .black]
    private static let widths: [CGFloat] = [2, 4, 8]

    static func open(_ item: CaptureItem) {
        if let existing = open.first(where: { $0.item === item }) {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        guard let image = item.image else { return }
        let controller = AnnotationEditorController(item: item, image: image)
        open.append(controller)
        AppPresence.windowOpened()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.window?.makeFirstResponder(controller.canvas)
        controller.window?.layoutIfNeeded()
        controller.zoomInitially()
    }

    private init(item: CaptureItem, image: CGImage) {
        self.item = item
        canvas = AnnotationCanvas(image: image, scale: item.scale)

        let screen = NSScreen.withMouse().visibleFrame
        let imageSize = CGSize(width: CGFloat(image.width) / item.scale, height: CGFloat(image.height) / item.scale)
        let size = CGSize(width: min(max(imageSize.width + 80, 900), screen.width * 0.9),
                          height: min(max(imageSize.height + 160, 560), screen.height * 0.9))
        let window = NSWindow(contentRect: CGRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2,
                                                  width: size.width, height: size.height),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = item.displayName
        window.minSize = CGSize(width: 860, height: 420)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: UI

    private func buildUI() {
        guard let window else { return }
        let content = NSView()
        window.contentView = content

        // Tools
        toolControl.segmentCount = AnnotationTool.allCases.count
        toolControl.trackingMode = .selectOne
        for (i, tool) in AnnotationTool.allCases.enumerated() {
            toolControl.setImage(NSImage(systemSymbolName: tool.symbol, accessibilityDescription: tool.title), forSegment: i)
            toolControl.setToolTip(tool.title, forSegment: i)
            toolControl.setWidth(30, forSegment: i)
        }
        toolControl.target = self
        toolControl.action = #selector(toolChanged)
        selectTool(.arrow)

        // Colors
        for (i, color) in Self.palette.enumerated() {
            let b = NSButton(image: Self.swatchImage(color, selected: i == 0), target: self, action: #selector(swatchClicked(_:)))
            b.isBordered = false
            b.tag = i
            swatches.append(b)
        }
        colorWell.color = .systemRed
        colorWell.target = self
        colorWell.action = #selector(colorWellChanged)

        widthControl.selectedSegment = 1
        widthControl.target = self
        widthControl.action = #selector(widthChanged)
        widthControl.setToolTip("Stroke / text size", forSegment: 0)

        undoButton = iconButton("arrow.uturn.backward", "Undo (⌘Z)", #selector(undoClicked))
        redoButton = iconButton("arrow.uturn.forward", "Redo (⇧⌘Z)", #selector(redoClicked))

        let top = NSStackView(views: [toolControl, separator()] + swatches + [colorWell, separator(), widthControl,
                                                                               separator(), undoButton, redoButton])
        top.spacing = 6
        top.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)

        // Bottom bar
        let backgroundButton = NSButton(title: "Background", image: NSImage(systemSymbolName: "square.on.square", accessibilityDescription: nil)!,
                                        target: self, action: #selector(showBackground(_:)))
        let actions = [
            NSButton(title: "Pin", image: NSImage(systemSymbolName: "pin", accessibilityDescription: nil)!, target: self, action: #selector(pin)),
            NSButton(title: "Share", image: NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: nil)!, target: self, action: #selector(share(_:))),
            NSButton(title: "Copy", image: NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)!, target: self, action: #selector(copyImage)),
            NSButton(title: "Save", image: NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: nil)!, target: self, action: #selector(saveDocument(_:))),
        ]
        let done = NSButton(title: "Done", target: self, action: #selector(done))
        done.keyEquivalent = "\r"
        done.keyEquivalentModifierMask = .command
        done.bezelColor = .controlAccentColor
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        zoomLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        zoomLabel.alignment = .center
        zoomLabel.widthAnchor.constraint(equalToConstant: 46).isActive = true
        let zoomOutButton = iconButton("minus.magnifyingglass", "Zoom Out (⌘−)", #selector(zoomOut(_:)))
        let zoomInButton = iconButton("plus.magnifyingglass", "Zoom In (⌘+)", #selector(zoomIn(_:)))
        let fitButton = NSButton(title: "Fit", target: self, action: #selector(zoomToFit(_:)))
        fitButton.toolTip = "Zoom to Fit (⌘0)"
        let actualButton = NSButton(title: "1:1", target: self, action: #selector(zoomToActualSize(_:)))
        actualButton.toolTip = "Actual Size (⌘1)"
        let bottom = NSStackView(views: [backgroundButton, separator(), zoomOutButton, zoomLabel, zoomInButton,
                                         fitButton, actualButton, spacer] + actions + [done])
        bottom.spacing = 8
        bottom.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 10, right: 12)

        scrollView.contentView = CenteringClipView()
        scrollView.documentView = canvas
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.02
        scrollView.maxMagnification = 16
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .underPageBackgroundColor
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(zoomChanged),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)

        for v in [top, scrollView, bottom] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: content.topAnchor),
            top.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            top.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor),
            scrollView.topAnchor.constraint(equalTo: top.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottom.topAnchor),
            bottom.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bottom.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bottom.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        canvas.onChange = { [weak self] in self?.refreshButtons() }
        canvas.onToolShortcut = { [weak self] tool in self?.selectTool(tool) }
        backgroundModel.onChange = { [weak self] style in self?.canvas.background = style }
        refreshButtons()
    }

    private func separator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: 1).isActive = true
        box.heightAnchor.constraint(equalToConstant: 20).isActive = true
        return box
    }

    private func iconButton(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: self, action: action)
        b.bezelStyle = .texturedRounded
        b.toolTip = tip
        return b
    }

    private static func swatchImage(_ color: NSColor, selected: Bool) -> NSImage {
        NSImage(size: NSSize(width: 20, height: 20), flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 3, dy: 3))
            color.setFill()
            circle.fill()
            NSColor.separatorColor.setStroke()
            circle.lineWidth = 1
            circle.stroke()
            if selected {
                let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.75, dy: 0.75))
                NSColor.controlAccentColor.setStroke()
                ring.lineWidth = 1.5
                ring.stroke()
            }
            return true
        }
    }

    private func refreshButtons() {
        undoButton.isEnabled = canvas.canUndo
        redoButton.isEnabled = canvas.canRedo
        window?.isDocumentEdited = canvas.isDirty
    }

    private func selectTool(_ tool: AnnotationTool) {
        toolControl.selectedSegment = AnnotationTool.allCases.firstIndex(of: tool) ?? 0
        canvas.tool = tool
    }

    private func setColor(_ color: NSColor, swatchIndex: Int?) {
        canvas.color = color
        for (i, b) in swatches.enumerated() {
            b.image = Self.swatchImage(Self.palette[i], selected: i == swatchIndex)
        }
        canvas.applyStyleToSelection()
    }

    @objc private func toolChanged() {
        canvas.tool = AnnotationTool.allCases[toolControl.selectedSegment]
        window?.makeFirstResponder(canvas)
    }

    @objc private func swatchClicked(_ sender: NSButton) {
        colorWell.color = Self.palette[sender.tag]
        setColor(Self.palette[sender.tag], swatchIndex: sender.tag)
    }

    @objc private func colorWellChanged() { setColor(colorWell.color, swatchIndex: nil) }

    @objc private func widthChanged() {
        canvas.widthPoints = Self.widths[widthControl.selectedSegment]
        canvas.applyStyleToSelection()
    }

    @objc private func undoClicked() { canvas.undo(nil) }
    @objc private func redoClicked() { canvas.redo(nil) }

    @objc private func showBackground(_ sender: NSButton) {
        if let popover = backgroundPopover, popover.isShown {
            popover.close()
            return
        }
        backgroundModel.style = canvas.background
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: BackgroundPanel(model: backgroundModel))
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
        backgroundPopover = popover
    }

    // MARK: Zoom

    /// Long captures (scrolling) open fitted to the width and scrolled to the top; others fit entirely.
    private func zoomInitially() {
        let size = canvas.frame.size
        if size.height > size.width * 2.5 {
            setMagnification(min(1, scrollView.contentSize.width / size.width))
            canvas.scroll(.zero)
        } else {
            zoomToFit(nil)
        }
    }

    private func setMagnification(_ value: CGFloat, centeredAt point: CGPoint? = nil) {
        let visible = scrollView.documentVisibleRect
        let center = point ?? CGPoint(x: visible.midX, y: visible.midY)
        scrollView.setMagnification(min(max(value, scrollView.minMagnification), scrollView.maxMagnification), centeredAt: center)
        zoomChanged()
    }

    @objc func zoomIn(_ sender: Any?) { setMagnification(scrollView.magnification * 1.25) }
    @objc func zoomOut(_ sender: Any?) { setMagnification(scrollView.magnification / 1.25) }
    @objc func zoomToActualSize(_ sender: Any?) { setMagnification(1) }

    @objc func zoomToFit(_ sender: Any?) {
        let size = canvas.frame.size, available = scrollView.contentSize
        setMagnification(min(1, available.width / size.width, available.height / size.height))
    }

    @objc private func zoomChanged() {
        zoomLabel.stringValue = "\(Int((scrollView.magnification * 100).rounded()))%"
    }

    // MARK: Actions

    private func export() -> CGImage? {
        guard let image = canvas.exportImage() else {
            HUD.error("Couldn't render the image")
            return nil
        }
        return image
    }

    @objc private func copyImage() {
        guard let image = export() else { return }
        Clipboard.copy(image: image, scale: item.scale)
        HUD.show("Copied to clipboard")
    }

    @objc func saveDocument(_ sender: Any?) {
        guard let image = export() else { return }
        if item.isExternal || item.savedURL == nil {
            item.update(image: image)
            if let url = item.save() { HUD.show("Saved \(url.lastPathComponent)") }
        } else {
            item.update(image: image)
            HUD.show("Saved")
        }
        canvas.markClean()
    }

    @objc func saveDocumentAs(_ sender: Any?) {
        guard let image = export(), let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic]
        panel.nameFieldStringValue = FileNaming.name(prefix: "Screenshot", ext: Prefs.imageFormat.fileExtension)
        panel.directoryURL = Prefs.saveFolder
        panel.beginSheetModal(for: window) { [item] response in
            guard response == .OK, let url = panel.url else { return }
            let format = ImageFormat.allCases.first { $0.fileExtension == url.pathExtension.lowercased() } ?? .png
            do {
                try image.encoded(as: format, scale: item.scale)?.write(to: url)
            } catch {
                HUD.error(error.localizedDescription)
            }
        }
    }

    @objc private func pin() {
        guard let image = export() else { return }
        PinManager.shared.pin(image: image, scale: item.scale)
    }

    @objc private func share(_ sender: NSButton) {
        guard let image = export(), let data = image.encoded(as: .png, scale: item.scale) else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(FileNaming.name(prefix: "Screenshot", ext: "png"))
        try? data.write(to: url)
        NSSharingServicePicker(items: [url]).show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    /// Applies the edits to the capture, copies it, and closes.
    @objc private func done() {
        guard let image = export() else { return }
        item.update(image: image)
        Clipboard.copy(image: image, scale: item.scale)
        canvas.markClean()
        window?.close()
        HUD.show("Copied to clipboard")
    }

    func windowWillClose(_ notification: Notification) {
        if canvas.isDirty, let image = canvas.exportImage() {
            item.update(image: image)
        }
        Self.open.removeAll { $0 === self }
        AppPresence.windowClosed()
    }
}

// MARK: - Background panel

final class BackgroundModel: ObservableObject {
    @Published var style = CanvasBackground() {
        didSet { if style != oldValue { onChange?(style) } }
    }
    var onChange: ((CanvasBackground) -> Void)?
}

struct BackgroundPanel: View {
    @ObservedObject var model: BackgroundModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Show background", isOn: $model.style.enabled)
                .toggleStyle(.switch)
                .font(.headline)

            LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 8), count: 8), spacing: 8) {
                ForEach(0..<CanvasBackground.presets.count, id: \.self) { i in
                    let colors = CanvasBackground.presets[i]
                    RoundedRectangle(cornerRadius: 6)
                        .fill(LinearGradient(colors: [Color(nsColor: colors.0), Color(nsColor: colors.1)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 30, height: 30)
                        .overlay(RoundedRectangle(cornerRadius: 6)
                            .stroke(model.style.preset == i ? Color.accentColor : Color.secondary.opacity(0.3),
                                    lineWidth: model.style.preset == i ? 2.5 : 1))
                        .onTapGesture {
                            model.style.preset = i
                            model.style.enabled = true
                        }
                }
            }

            LabeledContent("Padding") {
                Slider(value: $model.style.padding, in: 0...200)
            }
            LabeledContent("Corner radius") {
                Slider(value: $model.style.cornerRadius, in: 0...40)
            }
            Toggle("Shadow", isOn: $model.style.shadow)
            Picker("Aspect ratio", selection: $model.style.aspect) {
                ForEach(BackgroundAspect.allCases) { Text($0.rawValue).tag($0) }
            }
        }
        .padding(16)
        .frame(width: 330)
        .disabled(false)
    }
}

/// Keeps the canvas centered when it is smaller than the visible area.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return rect }
        if rect.width > document.frame.width { rect.origin.x = (document.frame.width - rect.width) / 2 }
        if rect.height > document.frame.height { rect.origin.y = (document.frame.height - rect.height) / 2 }
        return rect
    }
}
