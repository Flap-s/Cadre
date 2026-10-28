import AppKit
import XCTest
@testable import Cadre

final class TextRecognizerTests: XCTestCase {
    /// A tall Retina-like capture with normal-size UI text: a typical large OCR selection.
    private func render(lines: [String], width: Int, height: Int, fontSize: CGFloat, dark: Bool = false) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor((dark ? NSColor(white: 0.12, alpha: 1) : NSColor.white).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize),
            .foregroundColor: dark ? NSColor(white: 0.85, alpha: 1) : NSColor.black,
        ]
        for (i, line) in lines.enumerated() {
            NSAttributedString(string: line, attributes: attrs)
                .draw(at: CGPoint(x: 40, y: CGFloat(height) - 60 - CGFloat(i) * fontSize * 1.8))
        }
        NSGraphicsContext.current = nil
        return ctx.makeImage()!
    }

    private let sample = [
        "Le rapport trimestriel est prêt à être envoyé.",
        "Merci de vérifier les chiffres avant vendredi.",
        "The quick brown fox jumps over the lazy dog.",
        "Contact: support@example.com — 01 23 45 67 89",
    ]

    private func assertRecognized(_ image: CGImage, file: StaticString = #filePath, line: UInt = #line) async throws {
        let text = try await TextRecognizer.recognize(image)
        for expected in ["rapport trimestriel", "vérifier les chiffres", "quick brown fox", "support@example.com"] {
            XCTAssertTrue(text.contains(expected), "missing \"\(expected)\" in:\n\(text)", file: file, line: line)
        }
    }

    func testSmallTextInTallSelection() async throws {
        // 26 px text (13 pt on Retina) in a 2400 px tall selection: below Vision's default 1/32 minimum height.
        try await assertRecognized(render(lines: sample, width: 1800, height: 2400, fontSize: 26))
    }

    func testLightTextOnDarkBackground() async throws {
        try await assertRecognized(render(lines: sample, width: 1800, height: 2400, fontSize: 26, dark: true))
    }

    func testNonRetinaSmallText() async throws {
        // 12 pt text on a 1x display.
        try await assertRecognized(render(lines: sample, width: 900, height: 1200, fontSize: 12))
    }

    func testLinesComeOutInReadingOrder() async throws {
        let text = try await TextRecognizer.recognize(render(lines: sample, width: 1800, height: 600, fontSize: 30))
        let lines = text.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 4, text)
        XCTAssertTrue(lines.first?.hasPrefix("Le rapport") == true, text)
        XCTAssertTrue(lines.last?.hasPrefix("Contact") == true, text)
    }

    /// Draws one line tightly cropped, like selecting a single line on screen.
    private func tightLine(_ text: String, fontSize: CGFloat, padding: CGFloat) -> CGImage {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: fontSize), .foregroundColor: NSColor.black]
        let str = NSAttributedString(string: text, attributes: attrs)
        let size = str.size()
        let w = Int(size.width + padding * 2), h = Int(size.height + padding * 2)
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        str.draw(at: CGPoint(x: padding, y: padding))
        NSGraphicsContext.current = nil
        return ctx.makeImage()!
    }

    func testTightSingleLineAt1x() async throws {
        let text = try await TextRecognizer.recognize(tightLine("Numéro de commande : FR-2026-00417", fontSize: 12, padding: 2))
        XCTAssertTrue(text.contains("FR-2026-00417"), text)
    }

    func testSingleWord() async throws {
        let text = try await TextRecognizer.recognize(tightLine("Paramètres", fontSize: 13, padding: 3))
        XCTAssertEqual(text, "Paramètres")
    }

    func testCodeIsNotAutocorrected() async throws {
        let text = try await TextRecognizer.recognize(tightLine("let userId = fetchUsr(id: 42)", fontSize: 26, padding: 10))
        XCTAssertTrue(text.contains("fetchUsr"), text)
    }

    func testTinyTextInFullScreen() async throws {
        // 10 px text on a full 1x screen (1440×900).
        let text = try await TextRecognizer.recognize(render(lines: sample, width: 1440, height: 900, fontSize: 10))
        XCTAssertTrue(text.contains("quick brown fox"), text)
    }
}
