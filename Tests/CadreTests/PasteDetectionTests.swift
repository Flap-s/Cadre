import AppKit
import XCTest
@testable import Cadre

@MainActor
final class PasteDetectionTests: XCTestCase {
    private var pasteboard: NSPasteboard!

    override func setUp() async throws {
        pasteboard = NSPasteboard(name: NSPasteboard.Name("cadre-test-\(UUID().uuidString)"))
    }

    override func tearDown() async throws {
        pasteboard.releaseGlobally()
    }

    private func image(width: Int = 640, height: Int = 400) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(NSColor.systemOrange.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    private func spin(_ seconds: TimeInterval = 0.2) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func testPasteIsDetectedOnceAndGetsTheFullImage() throws {
        var pastes = 0
        Clipboard.copyLazily(image: image(), scale: 2, to: pasteboard) { pastes += 1 }

        // The image is advertised right away, but nothing is produced until someone pastes.
        XCTAssertTrue(pasteboard.types?.contains(.png) == true)
        spin()
        XCTAssertEqual(pastes, 0)

        let png = try XCTUnwrap(pasteboard.data(forType: .png))
        let pasted = try XCTUnwrap(NSBitmapImageRep(data: png))
        XCTAssertEqual(pasted.pixelsWide, 640)
        XCTAssertEqual(pasted.pixelsHigh, 400)
        spin()
        XCTAssertEqual(pastes, 1)

        // Pasting again, or in another format, doesn't fire again.
        _ = pasteboard.data(forType: .png)
        _ = pasteboard.data(forType: .tiff)
        spin()
        XCTAssertEqual(pastes, 1)
    }

    /// The real case: another process pastes while Cadre keeps running its event loop.
    func testPasteFromAnotherAppIsDetected() throws {
        var pastes = 0
        Clipboard.copyLazily(image: image(), scale: 2, to: pasteboard) { pastes += 1 }

        let reader = Process()
        reader.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        reader.arguments = ["-l", "JavaScript", "-e", """
            ObjC.import('AppKit');
            const pb = $.NSPasteboard.pasteboardWithName('\(pasteboard.name.rawValue)');
            const data = pb.dataForType('public.png');
            data.isNil() ? 0 : $.NSBitmapImageRep.imageRepWithData(data).pixelsWide;
            """]
        let out = Pipe()
        reader.standardOutput = out
        try reader.run()
        let deadline = Date().addingTimeInterval(20)
        while reader.isRunning && Date() < deadline { spin(0.05) }
        spin()
        let width = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(width, "640", "the other process should receive the full image")
        XCTAssertEqual(pastes, 1)
    }

    func testPasteClosesThatCapturesThumbnail() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("paste-\(UUID().uuidString).png")
        try image().encoded(as: .png, scale: 2)!.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let pastedItem = try XCTUnwrap(CaptureItem(imageAt: url))
        let otherItem = try XCTUnwrap(CaptureItem(imageAt: url))
        QuickAccessManager.shared.show(otherItem)
        QuickAccessManager.shared.show(pastedItem)
        defer { QuickAccessManager.shared.closeAll() }

        Clipboard.copyLazily(image: pastedItem.image!, scale: 2, to: pasteboard) { [weak pastedItem] in
            if let pastedItem { QuickAccessManager.shared.dismiss(pastedItem) }
        }
        XCTAssertTrue(QuickAccessManager.shared.visibleItems.contains { $0 === pastedItem })
        _ = pasteboard.data(forType: .png)
        spin()
        XCTAssertFalse(QuickAccessManager.shared.visibleItems.contains { $0 === pastedItem })
        XCTAssertTrue(QuickAccessManager.shared.visibleItems.contains { $0 === otherItem }, "other thumbnails stay")
    }

    func testUnusedPromiseBecomesRealDataBeforeQuitting() throws {
        var pastes = 0
        Clipboard.copyLazily(image: image(), scale: 2, to: pasteboard) { pastes += 1 }
        Clipboard.fulfillPendingPromise()
        let png = try XCTUnwrap(pasteboard.data(forType: .png))
        XCTAssertEqual(NSBitmapImageRep(data: png)?.pixelsWide, 640)
        spin()
        XCTAssertEqual(pastes, 0, "making the data concrete is not a paste")
    }

    func testPromiseIsLeftAloneOnceSomethingElseWasCopied() {
        Clipboard.copyLazily(image: image(), scale: 2, to: pasteboard) {}
        pasteboard.clearContents()
        pasteboard.setString("copied later", forType: .string)
        Clipboard.fulfillPendingPromise()
        XCTAssertEqual(pasteboard.string(forType: .string), "copied later")
    }
}
