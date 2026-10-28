import CoreGraphics
import Foundation

/// Stitches successive captures of a scrolling region into one tall image.
///
/// Each frame is reduced to per-row luminance signatures. The bottom half of the previous frame
/// (minus a margin for sticky footers) is searched for in the new frame; the vertical offset of the
/// best match is the scroll distance, and only the newly revealed rows are appended.
final class ScrollStitcher {
    enum Result: Equatable {
        case first
        case appended(Int)
        case noChange
        case noMatch
        case sizeMismatch
        case full
    }

    static let signatureColumns = 48
    /// Average per-sample luminance difference accepted as a match.
    static let matchThreshold = 6.0

    private struct Frame {
        let pixels: [UInt8]
        let signature: [UInt8]
    }

    private(set) var width = 0
    private(set) var height = 0
    private var margin = 0
    private var committed: [UInt8] = []
    private var committedRows = 0
    private var last: Frame?
    private var colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    var maxRows = 40_000

    var totalHeight: Int { last == nil ? 0 : committedRows + margin }

    func add(_ image: CGImage) -> Result {
        if last == nil {
            width = image.width
            height = image.height
            margin = height / 8
            colorSpace = image.colorSpace.usableRGB
            guard let frame = makeFrame(image) else { return .sizeMismatch }
            commit(frame, rows: 0..<(height - margin))
            last = frame
            return .first
        }
        guard image.width == width, image.height == height, let frame = makeFrame(image), let previous = last else {
            return .sizeMismatch
        }
        guard committedRows < maxRows else { return .full }
        guard let shift = offset(from: previous, to: frame) else { return .noMatch }
        if shift == 0 { return .noChange }
        commit(frame, rows: (height - margin - shift)..<(height - margin))
        last = frame
        return .appended(shift)
    }

    func makeImage() -> CGImage? {
        guard let last else { return nil }
        var bytes = committed
        let rowBytes = width * 4
        bytes.append(contentsOf: last.pixels[((height - margin) * rowBytes)..<(height * rowBytes)])
        let rows = committedRows + margin
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes,
                       space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    // MARK: Internals

    private func commit(_ frame: Frame, rows: Range<Int>) {
        let rowBytes = width * 4
        committed.append(contentsOf: frame.pixels[(rows.lowerBound * rowBytes)..<(rows.upperBound * rowBytes)])
        committedRows += rows.count
    }

    /// Scroll distance in pixels from `p` to `f` (0 = unchanged), or nil when no reliable match exists.
    private func offset(from p: Frame, to f: Frame) -> Int? {
        let h = height, cols = Self.signatureColumns
        let b0 = h / 2, b1 = h - margin, bandRows = b1 - b0
        guard bandRows > 8 else { return nil }

        // A featureless band (blank page) can't be located reliably.
        var textured = 0
        for row in b0..<b1 {
            let base = row * cols
            var lo = UInt8.max, hi = UInt8.min
            for c in 0..<cols { lo = min(lo, p.signature[base + c]); hi = max(hi, p.signature[base + c]) }
            if hi - lo > 12 { textured += 1 }
        }
        if textured < max(2, bandRows / 25) {
            return identical(p, f) ? 0 : nil
        }

        var best = Int.max, bestK = -1
        let sampledRows = stride(from: 0, to: bandRows, by: 2).map { $0 }
        // k = row in f where row b0 of p lands. Walk from k = b0 (no scroll) downwards so ties favor small shifts.
        for k in stride(from: b0, through: 0, by: -1) {
            var cost = 0
            for i in sampledRows {
                let pb = (b0 + i) * cols, fb = (k + i) * cols
                for c in 0..<cols {
                    cost += abs(Int(p.signature[pb + c]) - Int(f.signature[fb + c]))
                }
                if cost >= best { break }
            }
            if cost < best {
                best = cost
                bestK = k
            }
        }
        let average = Double(best) / Double(sampledRows.count * cols)
        guard bestK >= 0, average < Self.matchThreshold else { return nil }
        return b0 - bestK
    }

    private func identical(_ a: Frame, _ b: Frame) -> Bool {
        var diff = 0
        for i in 0..<a.signature.count { diff += abs(Int(a.signature[i]) - Int(b.signature[i])) }
        return Double(diff) / Double(a.signature.count) < 1
    }

    private func makeFrame(_ image: CGImage) -> Frame? {
        let rowBytes = width * 4
        var pixels = [UInt8](repeating: 0, count: rowBytes * height)
        let ok = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: rowBytes, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { return nil }

        let cols = Self.signatureColumns
        var signature = [UInt8](repeating: 0, count: cols * height)
        for y in 0..<height {
            let row = y * rowBytes
            for c in 0..<cols {
                let x0 = c * width / cols, x1 = max(x0 + 1, (c + 1) * width / cols)
                var sum = 0, n = 0
                var x = x0
                while x < x1 {
                    let i = row + x * 4
                    sum += (Int(pixels[i]) * 299 + Int(pixels[i + 1]) * 587 + Int(pixels[i + 2]) * 114) / 1000
                    n += 1
                    x += 2
                }
                signature[y * cols + c] = UInt8(sum / max(n, 1))
            }
        }
        return Frame(pixels: pixels, signature: signature)
    }
}
