import AppKit
import XCTest
@testable import Cadre

final class ScrollStitcherTests: XCTestCase {
    /// A tall synthetic "page" with distinct content on every row band.
    private func makePage(width: Int, height: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        var rng = SystemRandomNumberGenerator()
        var y = 0
        while y < height {
            let h = Int.random(in: 6...24, using: &rng)
            let x = Int.random(in: 0...(width / 2), using: &rng)
            let w = Int.random(in: 20...(width / 2), using: &rng)
            let gray = CGFloat.random(in: 0...0.7, using: &rng)
            ctx.setFillColor(CGColor(gray: gray, alpha: 1))
            ctx.fill(CGRect(x: x, y: y, width: w, height: h))
            y += h + Int.random(in: 2...10, using: &rng)
        }
        return ctx.makeImage()!
    }

    /// The viewport at `offset` rows from the top of the page.
    private func viewport(_ page: CGImage, top offset: Int, height: Int) -> CGImage {
        page.cropping(to: CGRect(x: 0, y: offset, width: page.width, height: height))!
    }

    private func pixels(_ image: CGImage) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let ctx = CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8,
                            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return data
    }

    func testStitchesScrolledFramesIntoOriginalPage() {
        let page = makePage(width: 300, height: 2000)
        let viewHeight = 400
        let stitcher = ScrollStitcher()
        var offset = 0
        XCTAssertEqual(stitcher.add(viewport(page, top: 0, height: viewHeight)), .first)
        for step in [37, 120, 0, 90, 150, 63, 180] {
            offset = min(offset + step, page.height - viewHeight)
            let result = stitcher.add(viewport(page, top: offset, height: viewHeight))
            XCTAssertEqual(result, step == 0 ? .noChange : .appended(step), "step \(step)")
        }
        let stitched = stitcher.makeImage()!
        XCTAssertEqual(stitched.height, offset + viewHeight)
        let expected = viewport(page, top: 0, height: offset + viewHeight)
        XCTAssertEqual(pixels(stitched), pixels(expected))
    }

    func testRejectsJumpTooLargeToMatch() {
        let page = makePage(width: 300, height: 2000)
        let stitcher = ScrollStitcher()
        _ = stitcher.add(viewport(page, top: 0, height: 400))
        XCTAssertEqual(stitcher.add(viewport(page, top: 900, height: 400)), .noMatch)
    }
}

@MainActor
final class RendererTests: XCTestCase {
    private func solid(_ color: NSColor, size: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(color.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        return ctx.makeImage()!
    }

    private func pixel(_ image: CGImage, x: Int, yFromTop y: Int) -> (UInt8, UInt8, UInt8) {
        var data = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (data[0], data[1], data[2])
    }

    func testFilledRectangleIsDrawnTopLeftOrigin() {
        let renderer = AnnotationRenderer(base: solid(.white, size: 100), scale: 1)
        let rect = Annotation(tool: .filledRectangle, points: [CGPoint(x: 0, y: 0), CGPoint(x: 40, y: 20)],
                              color: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), lineWidth: 2)
        let out = renderer.export(annotations: [rect], background: CanvasBackground())!
        XCTAssertEqual(out.width, 100)
        let inside = pixel(out, x: 20, yFromTop: 10)
        XCTAssertGreaterThan(inside.0, 200); XCTAssertLessThan(inside.1, 50)
        let outside = pixel(out, x: 20, yFromTop: 80)
        XCTAssertGreaterThan(outside.1, 200)
    }

    func testBackgroundAddsPadding() {
        let renderer = AnnotationRenderer(base: solid(.white, size: 100), scale: 2)
        var bg = CanvasBackground()
        bg.enabled = true
        bg.padding = 10
        let out = renderer.export(annotations: [], background: bg)!
        XCTAssertEqual(out.width, 140)
        XCTAssertEqual(out.height, 140)
        bg.aspect = .sixteenNine
        let wide = renderer.export(annotations: [], background: bg)!
        XCTAssertEqual(Double(wide.width) / Double(wide.height), 16.0 / 9, accuracy: 0.02)
    }

    func testPixelateChangesOnlyItsRegion() {
        // Half black / half white image; pixelating across the edge mixes them.
        let ctx = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(NSColor.white.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        for x in stride(from: 0, to: 100, by: 2) {
            ctx.setFillColor(NSColor.black.cgColor); ctx.fill(CGRect(x: x, y: 0, width: 1, height: 100))
        }
        let renderer = AnnotationRenderer(base: ctx.makeImage()!, scale: 1)
        let blur = Annotation(tool: .pixelate, points: [CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 100)], color: .red, lineWidth: 1)
        let out = renderer.export(annotations: [blur], background: CanvasBackground())!
        let inside = pixel(out, x: 10, yFromTop: 50)
        XCTAssert(inside.0 > 40 && inside.0 < 215, "pixelated region should average stripes, got \(inside.0)")
        let outside = pixel(out, x: 81, yFromTop: 50)
        XCTAssertGreaterThan(outside.0, 240)
    }
}

final class MiscTests: XCTestCase {
    func testURLNames() {
        XCTAssertEqual(CaptureAction.captureArea.urlName, "capture-area")
        XCTAssertEqual(CaptureAction.allInOne.urlName, "all-in-one")
        XCTAssertEqual(CaptureAction.recordGIF.urlName, "record-gif")
    }

    func testDefaultShortcutsAreUnique() {
        let combos = CaptureAction.allCases.compactMap(\.defaultCombo)
        XCTAssertEqual(Set(combos.map { "\($0.keyCode)-\($0.modifiers)" }).count, combos.count)
    }

    func testUniqueFileName() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let first = FileNaming.unique(in: dir, name: "Shot.png")
        try Data().write(to: first)
        XCTAssertEqual(FileNaming.unique(in: dir, name: "Shot.png").lastPathComponent, "Shot (2).png")
    }
}
