import AppKit

/// Interactive drawing surface of the annotation editor.
@MainActor
final class AnnotationCanvas: NSView, NSTextFieldDelegate {
    private struct Snapshot {
        let base: CGImage
        let annotations: [Annotation]
    }

    let renderer: AnnotationRenderer
    private(set) var annotations: [Annotation] = [] { didSet { needsDisplay = true } }
    var background = CanvasBackground() { didSet { syncFrameSize(); needsDisplay = true; isDirty = true } }

    var tool: AnnotationTool = .arrow {
        didSet {
            commitText()
            if tool != .select { selectedID = nil }
            cropRect = nil
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
        }
    }
    var color: NSColor = .systemRed
    var widthPoints: CGFloat = 4

    /// Undo state / dirty flag changed.
    var onChange: (() -> Void)?
    /// A tool was picked from the keyboard.
    var onToolShortcut: ((AnnotationTool) -> Void)?

    private(set) var isDirty = false
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    private var current: Annotation?
    private var selectedID: UUID? { didSet { needsDisplay = true } }
    private var dragOrigin: CGPoint?
    private var movedSinceDown = false
    private var cropStart: CGPoint?
    private var cropRect: CGRect?
    private var textField: NSTextField?
    private var editingText: Annotation?

    /// Canvas pixels -> view points. The view has the canvas' point size; zooming is done by the
    /// enclosing scroll view's magnification, so the image is always redrawn at full resolution.
    private var viewScale: CGFloat { 1 / scale }
    private let margin: CGFloat = 24
    private var canvasOrigin: CGPoint { CGPoint(x: margin, y: margin) }
    private var magnification: CGFloat { enclosingScrollView?.magnification ?? 1 }
    /// View points per image pixel as seen on screen, for hit-test tolerances.
    private var screenScale: CGFloat { viewScale * magnification }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    private var scale: CGFloat { renderer.scale }
    private var lineWidthPixels: CGFloat { widthPoints * scale }
    private var fontSizePixels: CGFloat { (12 + widthPoints * 3) * scale }

    init(image: CGImage, scale: CGFloat) {
        renderer = AnnotationRenderer(base: image, scale: scale)
        super.init(frame: .zero)
        syncFrameSize()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func exportImage() -> CGImage? {
        commitText()
        return renderer.export(annotations: annotations, background: background)
    }

    func markClean() {
        isDirty = false
        onChange?()
    }

    // MARK: Geometry

    private var imageOrigin: CGPoint { background.layout(imageSize: renderer.imageSize, scale: scale).imageOrigin }

    /// Canvas (image + background) size in view points.
    var canvasPointSize: CGSize {
        let canvas = background.layout(imageSize: renderer.imageSize, scale: scale).canvas
        return CGSize(width: canvas.width * viewScale, height: canvas.height * viewScale)
    }

    private func syncFrameSize() {
        let size = canvasPointSize
        setFrameSize(CGSize(width: size.width + margin * 2, height: size.height + margin * 2))
    }

    private func toImage(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - canvasOrigin.x) / viewScale - imageOrigin.x, y: (p.y - canvasOrigin.y) / viewScale - imageOrigin.y)
    }

    private func toView(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x + imageOrigin.x) * viewScale + canvasOrigin.x, y: (p.y + imageOrigin.y) * viewScale + canvasOrigin.y)
    }

    private func toView(_ r: CGRect) -> CGRect {
        let o = toView(r.origin)
        return CGRect(x: o.x, y: o.y, width: r.width * viewScale, height: r.height * viewScale)
    }

    private func imagePoint(_ event: NSEvent) -> CGPoint { toImage(convert(event.locationInWindow, from: nil)) }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.underPageBackgroundColor.setFill()
        dirtyRect.fill()
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        if !background.enabled {
            drawCheckerboard(in: toView(CGRect(origin: .zero, size: renderer.imageSize)))
        }

        ctx.saveGState()
        ctx.translateBy(x: canvasOrigin.x, y: canvasOrigin.y)
        ctx.scaleBy(x: viewScale, y: viewScale)
        ctx.interpolationQuality = .high
        var visible = annotations.filter { $0.id != editingText?.id }
        if let current { visible.append(current) }
        renderer.render(annotations: visible, background: background, in: ctx)
        ctx.restoreGState()

        if let id = selectedID, let a = annotations.first(where: { $0.id == id }) {
            let r = toView(a.bounds).insetBy(dx: -4 / magnification, dy: -4 / magnification)
            NSColor.controlAccentColor.setStroke()
            let path = NSBezierPath(rect: r)
            path.lineWidth = 1 / magnification
            path.setLineDash([4 / magnification, 3 / magnification], count: 2, phase: 0)
            path.stroke()
        }

        if let crop = cropRect {
            let image = toView(CGRect(origin: .zero, size: renderer.imageSize))
            let r = toView(crop)
            NSColor.black.withAlphaComponent(0.5).setFill()
            let dim = NSBezierPath(rect: image)
            dim.appendRect(r)
            dim.windingRule = .evenOdd
            dim.fill()
            NSColor.white.setStroke()
            let border = NSBezierPath(rect: r)
            border.lineWidth = 1 / magnification
            border.stroke()
            let label = NSAttributedString(string: "\(Int(crop.width)) × \(Int(crop.height))",
                                           attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11 / magnification, weight: .medium),
                                                        .foregroundColor: NSColor.white])
            label.draw(at: CGPoint(x: r.minX + 4 / magnification, y: r.maxY + 4 / magnification))
        }
    }

    private func drawCheckerboard(in rect: CGRect) {
        NSColor.white.setFill()
        rect.fill()
        NSColor(white: 0.9, alpha: 1).setFill()
        let size: CGFloat = 8
        var y = rect.minY, row = 0
        while y < rect.maxY {
            var x = rect.minX + (row % 2 == 0 ? 0 : size)
            while x < rect.maxX {
                CGRect(x: x, y: y, width: size, height: size).intersection(rect).fill()
                x += size * 2
            }
            y += size
            row += 1
        }
    }

    override func resetCursorRects() {
        switch tool {
        case .select: addCursorRect(bounds, cursor: .arrow)
        case .text: addCursorRect(bounds, cursor: .iBeam)
        default: addCursorRect(bounds, cursor: .crosshair)
        }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let hadText = textField != nil
        commitText()
        window?.makeFirstResponder(self)
        let p = imagePoint(event)
        movedSinceDown = false

        // Only the canvas (image + background) is exported; ignore drawing in the margin around it.
        let canvasRect = CGRect(origin: canvasOrigin, size: canvasPointSize)
        if tool != .select, !canvasRect.contains(convert(event.locationInWindow, from: nil)) { return }

        switch tool {
        case .select:
            let tolerance = 6 / screenScale
            if let hit = annotations.last(where: { $0.hitTest(p, tolerance: tolerance) }) {
                selectedID = hit.id
                dragOrigin = p
                if event.clickCount == 2, hit.tool == .text { beginText(editing: hit) }
            } else {
                selectedID = nil
            }
        case .text:
            if !hadText {
                if let hit = annotations.last(where: { $0.tool == .text && $0.hitTest(p, tolerance: 4 / screenScale) }) {
                    beginText(editing: hit)
                } else {
                    beginText(editing: Annotation(tool: .text, points: [p], color: color, lineWidth: lineWidthPixels,
                                                  fontSize: fontSizePixels))
                }
            }
        case .counter:
            pushUndo()
            let next = (annotations.filter { $0.tool == .counter }.map(\.number).max() ?? 0) + 1
            annotations.append(Annotation(tool: .counter, points: [p], color: color, lineWidth: lineWidthPixels,
                                          fontSize: fontSizePixels, number: next))
        case .crop:
            cropStart = p
            cropRect = nil
        default:
            current = Annotation(tool: tool, points: tool.isFreehand ? [p] : [p, p], color: color,
                                 lineWidth: tool == .highlighter ? lineWidthPixels * 4 : lineWidthPixels)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = imagePoint(event)
        switch tool {
        case .select:
            guard let id = selectedID, let origin = dragOrigin,
                  let index = annotations.firstIndex(where: { $0.id == id }) else { return }
            if !movedSinceDown { pushUndo(); movedSinceDown = true }
            annotations[index].offset(by: p - origin)
            dragOrigin = p
        case .crop:
            guard let start = cropStart else { return }
            cropRect = CGRect(corner: start, p).intersection(CGRect(origin: .zero, size: renderer.imageSize))
            needsDisplay = true
        default:
            guard var c = current else { return }
            if c.tool.isFreehand {
                c.points.append(p)
            } else {
                c.points = [c.start, event.modifierFlags.contains(.shift) ? constrained(from: c.start, to: p, tool: c.tool) : p]
            }
            current = c
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        dragOrigin = nil
        switch tool {
        case .crop:
            if let r = cropRect, r.width > 8, r.height > 8 { applyCrop(r) }
            cropRect = nil
            cropStart = nil
            needsDisplay = true
        default:
            guard let c = current else { return }
            current = nil
            let meaningful = c.tool.isFreehand ? c.points.count > 1 : (c.rect.width > 2 || c.rect.height > 2)
            if meaningful {
                pushUndo()
                annotations.append(c)
            }
            needsDisplay = true
        }
    }

    private func constrained(from a: CGPoint, to b: CGPoint, tool: AnnotationTool) -> CGPoint {
        let dx = b.x - a.x, dy = b.y - a.y
        switch tool {
        case .arrow, .line:
            let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
            let length = hypot(dx, dy)
            return CGPoint(x: a.x + cos(angle) * length, y: a.y + sin(angle) * length)
        default:
            let side = max(abs(dx), abs(dy))
            return CGPoint(x: a.x + (dx < 0 ? -side : side), y: a.y + (dy < 0 ? -side : side))
        }
    }

    // MARK: Editing operations

    private func pushUndo() {
        undoStack.append(Snapshot(base: renderer.base, annotations: annotations))
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
        isDirty = true
        onChange?()
    }

    private func restore(_ s: Snapshot) {
        if s.base !== renderer.base {
            renderer.setBase(s.base)
            syncFrameSize()
        }
        annotations = s.annotations
        selectedID = nil
        isDirty = true
        onChange?()
        needsDisplay = true
    }

    @objc func undo(_ sender: Any?) {
        commitText()
        guard let s = undoStack.popLast() else { return }
        redoStack.append(Snapshot(base: renderer.base, annotations: annotations))
        restore(s)
    }

    @objc func redo(_ sender: Any?) {
        guard let s = redoStack.popLast() else { return }
        undoStack.append(Snapshot(base: renderer.base, annotations: annotations))
        restore(s)
    }

    @objc func delete(_ sender: Any?) { deleteSelection() }

    private func deleteSelection() {
        guard let id = selectedID else { return }
        pushUndo()
        annotations.removeAll { $0.id == id }
        selectedID = nil
    }

    func applyStyleToSelection() {
        guard let id = selectedID, let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        pushUndo()
        annotations[index].color = color
        let tool = annotations[index].tool
        annotations[index].lineWidth = tool == .highlighter ? lineWidthPixels * 4 : lineWidthPixels
        if tool == .text || tool == .counter { annotations[index].fontSize = fontSizePixels }
    }

    private func applyCrop(_ rect: CGRect) {
        let r = rect.integral.intersection(CGRect(origin: .zero, size: renderer.imageSize))
        guard let cropped = renderer.base.cropping(to: r) else { return }
        pushUndo()
        renderer.setBase(cropped)
        syncFrameSize()
        annotations = annotations.map { var a = $0; a.offset(by: CGPoint(x: -r.minX, y: -r.minY)); return a }
        tool = .select
        onToolShortcut?(.select)
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control])
        switch Int(event.keyCode) {
        case 51, 117:
            deleteSelection()
            return
        case 53:
            if cropRect != nil { cropRect = nil; needsDisplay = true } else { selectedID = nil }
            return
        case 123, 124, 125, 126:
            nudge(event)
            return
        default:
            break
        }
        if flags.isEmpty, let c = event.charactersIgnoringModifiers?.lowercased().first,
           let t = AnnotationTool.allCases.first(where: { $0.shortcut == c }) {
            tool = t
            onToolShortcut?(t)
            return
        }
        super.keyDown(with: event)
    }

    private func nudge(_ event: NSEvent) {
        guard let id = selectedID, let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        let step = (event.modifierFlags.contains(.shift) ? 10 : 1) / screenScale
        let d: CGPoint
        switch Int(event.keyCode) {
        case 123: d = CGPoint(x: -step, y: 0)
        case 124: d = CGPoint(x: step, y: 0)
        case 125: d = CGPoint(x: 0, y: step)
        default: d = CGPoint(x: 0, y: -step)
        }
        pushUndo()
        annotations[index].offset(by: d)
    }

    // MARK: Text

    private func beginText(editing annotation: Annotation) {
        editingText = annotation
        let field = NSTextField(string: annotation.text)
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: annotation.fontSize * viewScale, weight: .bold)
        field.textColor = annotation.color
        field.delegate = self
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        let origin = toView(annotation.start)
        let height = annotation.fontSize * viewScale * 1.35
        field.frame = NSRect(x: origin.x - 2, y: origin.y - 1, width: max(160, annotation.textSize.width * viewScale + 40), height: height)
        addSubview(field)
        textField = field
        window?.makeFirstResponder(field)
        needsDisplay = true
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = textField else { return }
        let width = field.attributedStringValue.size().width + 40
        field.frame.size.width = max(160, width)
    }

    func controlTextDidEndEditing(_ obj: Notification) { commitText() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) || selector == #selector(NSResponder.cancelOperation(_:)) {
            commitText()
            return true
        }
        return false
    }

    private func commitText() {
        guard let field = textField, var a = editingText else { return }
        textField = nil
        editingText = nil
        a.text = field.stringValue
        field.removeFromSuperview()

        let existing = annotations.firstIndex { $0.id == a.id }
        let empty = a.text.trimmingCharacters(in: .whitespaces).isEmpty
        if existing != nil || !empty {
            if let existing, annotations[existing].text == a.text {
                // unchanged
            } else {
                pushUndo()
                if let existing {
                    if empty { annotations.remove(at: existing) } else { annotations[existing] = a }
                } else {
                    annotations.append(a)
                }
            }
        }
        window?.makeFirstResponder(self)
        needsDisplay = true
    }
}

extension AnnotationCanvas: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)): return canUndo
        case #selector(redo(_:)): return canRedo
        case #selector(delete(_:)): return selectedID != nil
        default: return true
        }
    }
}
