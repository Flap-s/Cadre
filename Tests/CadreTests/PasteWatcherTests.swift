import AppKit
import XCTest
@testable import Cadre

@MainActor
final class PasteWatcherTests: XCTestCase {
    private var pasteboard: NSPasteboard!
    private var watcher: PasteWatcher!
    private var pasted: [CaptureItem] = []

    override func setUp() async throws {
        pasteboard = NSPasteboard(name: NSPasteboard.Name("cadre-test-\(UUID().uuidString)"))
        watcher = PasteWatcher()
        pasted = []
        watcher.onPaste = { [unowned self] in self.pasted.append($0) }
    }

    override func tearDown() async throws {
        watcher.stop()
        pasteboard.releaseGlobally()
    }

    private func capture() throws -> CaptureItem {
        let ctx = CGContext(data: nil, width: 320, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(NSColor.systemPink.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: 320, height: 200))
        let image = ctx.makeImage()!
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pw-\(UUID().uuidString).png")
        try image.encoded(as: .png, scale: 2)!.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let item = try XCTUnwrap(CaptureItem(imageAt: url))
        Clipboard.copy(image: image, scale: 2, to: pasteboard)
        watcher.watch(item, pasteboard: pasteboard)
        return item
    }

    private func spin() { RunLoop.main.run(until: Date().addingTimeInterval(0.35)) }

    /// The bug: Spotlight's clipboard history (or a clipboard manager) reads every copy. That must not
    /// count as a paste.
    func testBackgroundClipboardReaderDoesNotCloseThumbnail() throws {
        _ = try capture()
        let reader = Process()
        reader.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        reader.arguments = ["-l", "JavaScript", "-e",
                            "ObjC.import('AppKit'); $.NSPasteboard.pasteboardWithName('\(pasteboard.name.rawValue)').dataForType('public.png').length"]
        reader.standardOutput = Pipe()
        try reader.run()
        reader.waitUntilExit()
        spin()
        XCTAssertTrue(pasted.isEmpty)
        XCTAssertTrue(watcher.isWatching)
    }

    func testCommandVClosesTheCapturesThumbnail() throws {
        let item = try capture()
        watcher.handleKeyDown(characters: "v", keyCode: 9, modifiers: .command)
        spin()
        XCTAssertEqual(pasted.count, 1)
        XCTAssertTrue(pasted.first === item)
        XCTAssertFalse(watcher.isWatching)
        // Pasting again later doesn't fire twice.
        watcher.handleKeyDown(characters: "v", keyCode: 9, modifiers: .command)
        spin()
        XCTAssertEqual(pasted.count, 1)
    }

    func testPasteAndMatchStyleAndAZERTYCount() throws {
        _ = try capture()
        watcher.handleKeyDown(characters: "V", keyCode: 9, modifiers: [.command, .option, .shift])
        spin()
        XCTAssertEqual(pasted.count, 1)
    }

    func testOtherShortcutsAndTypingDoNotCount() throws {
        _ = try capture()
        watcher.handleKeyDown(characters: "c", keyCode: 8, modifiers: .command)
        watcher.handleKeyDown(characters: "v", keyCode: 9, modifiers: [])
        watcher.handleKeyDown(characters: "v", keyCode: 9, modifiers: [.command, .control])
        spin()
        XCTAssertTrue(pasted.isEmpty)
        XCTAssertTrue(watcher.isWatching)
    }

    func testCopyingSomethingElseCancelsTheWatch() throws {
        _ = try capture()
        pasteboard.clearContents()
        pasteboard.setString("copied later", forType: .string)
        watcher.handleKeyDown(characters: "v", keyCode: 9, modifiers: .command)
        spin()
        XCTAssertTrue(pasted.isEmpty, "⌘V now pastes something else, the capture stays")
        XCTAssertFalse(watcher.isWatching)
    }

    func testClosingTheThumbnailStopsWatching() throws {
        let item = try capture()
        watcher.forget(item)
        XCTAssertFalse(watcher.isWatching)
        XCTAssertFalse(watcher.isMonitoringKeys)
    }
}
