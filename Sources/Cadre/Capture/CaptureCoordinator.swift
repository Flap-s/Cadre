import AppKit
import Vision

/// Orchestrates every capture mode and what happens after a capture.
@MainActor
final class CaptureCoordinator {
    static let shared = CaptureCoordinator()

    private var previousArea: (displayID: CGDirectDisplayID, rect: CGRect)?

    // MARK: Modes

    func captureArea() {
        withOverlay(.area) { await self.screenshot($0) }
    }

    func captureWindow() {
        withOverlay(.window) { await self.screenshot($0) }
    }

    func allInOne() {
        withOverlay(.allInOne) { sel in
            switch sel.action {
            case .screenshot: await self.screenshot(sel)
            case .pin: await self.pin(sel)
            case .text: await self.recognizeText(sel)
            case .scrolling: ScrollingCaptureSession.start(screen: sel.screen, rect: sel.localRect)
            case .recordVideo: await ScreenRecorder.shared.start(selection: sel, gif: false)
            case .recordGIF: await ScreenRecorder.shared.start(selection: sel, gif: true)
            }
        }
    }

    func captureFullscreen() {
        let screen = NSScreen.withMouse()
        Task {
            guard await ensureReady() else { return }
            await withHiddenIcons {
                do {
                    let captured = try await ScreenCapturer.captureScreen(screen, showCursor: Prefs.captureCursor)
                    self.deliver(captured)
                } catch {
                    HUD.error(error.localizedDescription)
                }
            }
        }
    }

    func capturePreviousArea() {
        guard let previous = previousArea, let screen = NSScreen.with(displayID: previous.displayID) else {
            captureArea()
            return
        }
        Task {
            guard await ensureReady() else { return }
            await withHiddenIcons {
                do {
                    let captured = try await ScreenCapturer.captureScreen(screen, rect: previous.rect, showCursor: Prefs.captureCursor)
                    self.deliver(captured)
                } catch {
                    HUD.error(error.localizedDescription)
                }
            }
        }
    }

    func selfTimer() {
        withOverlay(.area) { sel in
            await Countdown.run(seconds: Prefs.selfTimerSeconds, on: sel.screen,
                                centeredIn: sel.isFullscreen ? nil : sel.globalRect)
            var live = sel
            live.frozenImage = nil
            await self.screenshot(live, forceLive: true)
        }
    }

    func scrollingCapture() {
        withOverlay(.area) { sel in
            ScrollingCaptureSession.start(screen: sel.screen, rect: sel.localRect)
        }
    }

    func captureText() {
        withOverlay(.area) { await self.recognizeText($0) }
    }

    func captureAndPin() {
        withOverlay(.area) { await self.pin($0) }
    }

    func record(gif: Bool) {
        if ScreenRecorder.shared.isActive {
            Task { await ScreenRecorder.shared.stop() }
            return
        }
        withOverlay(.area, keepIconsHidden: true) { sel in
            await ScreenRecorder.shared.start(selection: sel, gif: gif)
        }
    }

    func annotateClipboard() {
        guard let (image, scale) = Clipboard.image() else {
            HUD.error("No image on the clipboard")
            return
        }
        AnnotationEditorController.open(CaptureItem(image: image, scale: scale))
    }

    // MARK: Plumbing

    private func ensureReady() async -> Bool {
        guard !OverlaySession.isActive, !ScrollingCaptureSession.isActive else { return false }
        return await Permissions.ensureScreenRecording()
    }

    private func withHiddenIcons(_ body: () async -> Void) async {
        let hide = Prefs.hideDesktopIconsWhileCapturing && !DesktopIconsHider.shared.isHidden
        if hide { await DesktopIconsHider.shared.hide() }
        await body()
        if hide { DesktopIconsHider.shared.show() }
    }

    private func withOverlay(_ mode: OverlayMode, keepIconsHidden: Bool = false,
                             _ body: @escaping (OverlaySelection) async -> Void) {
        Task {
            guard await ensureReady() else { return }
            let hide = Prefs.hideDesktopIconsWhileCapturing && !DesktopIconsHider.shared.isHidden
            if hide { await DesktopIconsHider.shared.hide() }
            OverlaySession.begin(mode: mode) { selection in
                Task {
                    if let selection { await body(selection) }
                    if hide && !keepIconsHidden { DesktopIconsHider.shared.show() }
                }
            }
        }
    }

    private func grab(_ sel: OverlaySelection, forceLive: Bool = false) async -> Captured? {
        do {
            if let windowID = sel.windowID {
                return try await ScreenCapturer.captureWindow(windowID, shadow: Prefs.windowShadow)
            }
            if Prefs.freezeScreen, !forceLive, let frozen = sel.croppedFrozen() {
                return frozen
            }
            return try await ScreenCapturer.captureScreen(sel.screen, rect: sel.isFullscreen ? nil : sel.localRect,
                                                          showCursor: Prefs.captureCursor)
        } catch {
            HUD.error(error.localizedDescription)
            return nil
        }
    }

    private func screenshot(_ sel: OverlaySelection, forceLive: Bool = false) async {
        if sel.windowID == nil { previousArea = (sel.screen.displayID, sel.localRect) }
        guard let captured = await grab(sel, forceLive: forceLive) else { return }
        deliver(captured)
    }

    private func pin(_ sel: OverlaySelection) async {
        guard let captured = await grab(sel) else { return }
        Sound.capture()
        PinManager.shared.pin(image: captured.image, scale: captured.scale,
                              frame: sel.windowID == nil ? sel.globalRect : nil)
    }

    private func recognizeText(_ sel: OverlaySelection) async {
        guard let captured = await grab(sel) else { return }
        HUD.show("Recognizing text…", symbol: "text.viewfinder", duration: 30)
        do {
            let text = try await TextRecognizer.recognize(captured.image)
            if text.isEmpty {
                HUD.error("No text found")
            } else {
                Clipboard.copy(text: text)
                Sound.done()
                HUD.show("Text copied", symbol: "text.viewfinder")
            }
        } catch {
            HUD.error(error.localizedDescription)
        }
    }

    /// Post-capture pipeline: sound → history → save / copy → Quick Access Overlay or editor.
    func deliver(_ captured: Captured, prefix: String = "Screenshot") {
        Sound.capture()
        var image = captured.image, scale = captured.scale
        if Prefs.downscaleRetina, scale > 1, let small = image.resized(by: 1 / scale) {
            image = small
            scale = 1
        }
        let item = CaptureItem(image: image, scale: scale, prefix: prefix)
        if Prefs.afterCaptureSave { item.save() }
        if Prefs.afterCaptureCopy { item.copyToPasteboard() }
        if Prefs.afterCaptureOpenEditor {
            AnnotationEditorController.open(item)
        } else if Prefs.afterCaptureShowOverlay {
            QuickAccessManager.shared.show(item)
        } else if !Prefs.afterCaptureSave && !Prefs.afterCaptureCopy {
            QuickAccessManager.shared.show(item)
        }
    }

    func deliverVideo(at url: URL) {
        Sound.done()
        let item = CaptureItem(videoAt: url, temporary: true)
        if Prefs.afterCaptureSave { item.save() }
        if Prefs.afterCaptureCopy { item.copyToPasteboard() }
        QuickAccessManager.shared.show(item)
    }
}

enum TextRecognizer {
    /// Recognized text in reading order (one line per row of text) plus any QR / barcode payloads.
    static func recognize(_ image: CGImage) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let prepared = prepare(image)
            let text = VNRecognizeTextRequest()
            text.recognitionLevel = .accurate
            text.usesLanguageCorrection = true
            // Auto-detection guesses wrong on short selections (e.g. drops French accents), so use
            // the user's own languages, then English.
            text.automaticallyDetectsLanguage = false
            text.recognitionLanguages = languages(supported: (try? text.supportedRecognitionLanguages()) ?? [])
            // The default ignores text shorter than 1/32 of the image height.
            text.minimumTextHeight = min(1, 6 / Float(max(prepared.height, 1)))
            let codes = VNDetectBarcodesRequest()
            try VNImageRequestHandler(cgImage: prepared).perform([text, codes])

            var lines = readingOrder(text.results ?? [])
            let payloads = (codes.results ?? []).compactMap(\.payloadStringValue)
            lines.append(contentsOf: payloads.filter { !lines.contains($0) })
            return lines.joined(separator: "\n")
        }.value
    }

    /// Preferred system languages Vision supports, then English.
    static func languages(supported: [String]) -> [String] {
        var result: [String] = []
        for preferred in Locale.preferredLanguages + ["en-US"] {
            let code = preferred.split(separator: "-").first.map(String.init) ?? preferred
            if let match = supported.first(where: { $0 == preferred }) ?? supported.first(where: { $0.hasPrefix(code) }),
               !result.contains(match) {
                result.append(match)
            }
        }
        return result.isEmpty ? ["en-US"] : result
    }

    /// Small crops (a single line, a word) are recognized far better when enlarged and given a margin.
    static func prepare(_ image: CGImage) -> CGImage {
        guard image.height < 240 || image.width < 240 else { return image }
        let factor: CGFloat = image.height < 60 ? 3 : 2
        let pad = CGFloat(max(12, image.height / 2)) * factor
        let w = Int(CGFloat(image.width) * factor + pad * 2), h = Int(CGFloat(image.height) * factor + pad * 2)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        ctx.setFillColor(cornerColor(of: image))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: pad, y: pad, width: CGFloat(image.width) * factor, height: CGFloat(image.height) * factor))
        return ctx.makeImage() ?? image
    }

    /// Background color guess for the margin: the top-left pixel.
    private static func cornerColor(of image: CGImage) -> CGColor {
        var px = [UInt8](repeating: 255, count: 4)
        if let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            ctx.draw(image, in: CGRect(x: 0, y: -(image.height - 1), width: image.width, height: image.height))
        }
        return CGColor(srgbRed: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255, blue: CGFloat(px[2]) / 255, alpha: 1)
    }

    /// Groups observations into rows (top to bottom), each row read left to right.
    static func readingOrder(_ observations: [VNRecognizedTextObservation]) -> [String] {
        let items = observations.compactMap { o in o.topCandidates(1).first.map { (box: o.boundingBox, text: $0.string) } }
            .sorted { $0.box.midY > $1.box.midY } // Vision's origin is bottom-left
        var rows: [[(box: CGRect, text: String)]] = []
        for item in items {
            if let last = rows.last?.last, abs(last.box.midY - item.box.midY) < min(last.box.height, item.box.height) * 0.5 {
                rows[rows.count - 1].append(item)
            } else {
                rows.append([item])
            }
        }
        return rows.map { $0.sorted { $0.box.minX < $1.box.minX }.map(\.text).joined(separator: " ") }
    }
}
