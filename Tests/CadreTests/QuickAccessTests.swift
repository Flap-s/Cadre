import AppKit
import XCTest
@testable import Cadre

@MainActor
final class QuickAccessTests: XCTestCase {
    private func makeItem() throws -> CaptureItem {
        let ctx = CGContext(data: nil, width: 800, height: 500, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(NSColor.systemTeal.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: 800, height: 500))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("qa-\(UUID().uuidString).png")
        try ctx.makeImage()!.encoded(as: .png, scale: 2)!.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return try XCTUnwrap(CaptureItem(imageAt: url))
    }

    /// While hovered, a press anywhere off the buttons must reach the card itself and be accepted as a
    /// first click: the panel is never key beforehand, and a refused first click swallows the drag.
    func testHoveredThumbnailAcceptsFirstClickForDragging() throws {
        let panel = QuickAccessPanel(item: try makeItem())
        let card = try XCTUnwrap(panel.contentView)
        card.layoutSubtreeIfNeeded()
        card.mouseEntered(with: NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                                                       windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0,
                                                       userData: nil)!)
        let b = card.bounds
        // Points on the image, away from the Copy/Save pills and the corner buttons.
        for point in [CGPoint(x: b.midX, y: b.maxY - 12), CGPoint(x: b.midX, y: b.minY + 12), CGPoint(x: b.minX + 50, y: b.midY)] {
            let hit = try XCTUnwrap(card.hitTest(point), "\(point)")
            XCTAssertTrue(hit === card, "\(point) went to \(type(of: hit))")
            XCTAssertTrue(hit.acceptsFirstMouse(for: nil))
        }
        // The buttons still get their clicks, on the first click too.
        let center = try XCTUnwrap(card.hitTest(CGPoint(x: b.midX, y: b.midY + 20)))
        XCTAssertTrue(center is NSButton, "center went to \(type(of: center))")
        XCTAssertTrue(center.acceptsFirstMouse(for: nil))
        let close = try XCTUnwrap(card.hitTest(CGPoint(x: b.minX + 21, y: b.maxY - 21)))
        XCTAssertTrue(close is NSButton)
        XCTAssertTrue(close.acceptsFirstMouse(for: nil))
    }

    func testCapturesAreCopiedByDefault() {
        Prefs.registerDefaults()
        XCTAssertEqual(UserDefaults.standard.volatileDomain(forName: UserDefaults.registrationDomain)[PrefKey.afterCaptureCopy] as? Bool, true)
    }
}
