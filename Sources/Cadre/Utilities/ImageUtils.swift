import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

extension CGImage {
    var pointSize: CGSize { CGSize(width: width, height: height) }

    func nsImage(scale: CGFloat) -> NSImage {
        NSImage(cgImage: self, size: CGSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale))
    }

    func encoded(as format: ImageFormat, scale: CGFloat, quality: Double = Prefs.jpegQuality) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, format.utType.identifier as CFString, 1, nil) else { return nil }
        var props: [CFString: Any] = [
            kCGImagePropertyDPIWidth: 72 * scale,
            kCGImagePropertyDPIHeight: 72 * scale,
        ]
        if format != .png { props[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(dest, self, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    func resized(by factor: CGFloat) -> CGImage? {
        let w = max(1, Int(CGFloat(width) * factor)), h = max(1, Int(CGFloat(height) * factor))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: colorSpace.usableRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(self, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    static func load(from url: URL) -> (image: CGImage, scale: CGFloat)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let dpi = (props?[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 72
        return (image, max(1, (dpi / 72).rounded()))
    }

    static func thumbnail(of url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary)
    }
}

extension Optional where Wrapped == CGColorSpace {
    /// A color space usable for an RGB bitmap context.
    var usableRGB: CGColorSpace {
        if let cs = self, cs.model == .rgb, cs.supportsOutput { return cs }
        return CGColorSpace(name: CGColorSpace.sRGB)!
    }
}

extension NSImage {
    var cgImage: CGImage? { cgImage(forProposedRect: nil, context: nil, hints: nil) }
}

enum FileNaming {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f
    }()

    static func name(prefix: String, ext: String, date: Date = Date()) -> String {
        "\(prefix) \(formatter.string(from: date)).\(ext)"
    }

    /// `dir/name.ext`, or `dir/name (2).ext` etc. if it already exists.
    static func unique(in dir: URL, name: String) -> URL {
        let fm = FileManager.default
        var url = dir.appendingPathComponent(name)
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        var n = 2
        while fm.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base) (\(n))").appendingPathExtension(ext)
            n += 1
        }
        return url
    }
}

enum Clipboard {
    static func copy(image: CGImage, scale: CGFloat, to pb: NSPasteboard = .general) {
        pb.clearContents()
        let ns = image.nsImage(scale: scale)
        if let png = image.encoded(as: .png, scale: scale) { pb.setData(png, forType: .png) }
        if let tiff = ns.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
    }

    @MainActor private static var pending: (provider: LazyImageProvider, pasteboard: NSPasteboard, changeCount: Int)?

    /// Puts the image on the pasteboard as a promise: the PNG/TIFF data is only produced when an app
    /// asks for it, which is when the user pastes. `onPaste` runs once, on the main thread, at that moment.
    @MainActor static func copyLazily(image: CGImage, scale: CGFloat, to pb: NSPasteboard = .general,
                                      onPaste: @escaping @MainActor () -> Void) {
        let provider = LazyImageProvider(image: image, scale: scale, onPaste: onPaste)
        let item = NSPasteboardItem()
        item.setDataProvider(provider, forTypes: [.png, .tiff])
        pb.clearContents()
        pb.writeObjects([item])
        pending = (provider, pb, pb.changeCount)
    }

    /// A promise dies with the app, so before quitting turn a still-unused one into real data.
    @MainActor static func fulfillPendingPromise() {
        guard let p = pending else { return }
        pending = nil
        guard p.pasteboard.changeCount == p.changeCount, !p.provider.delivered else { return }
        copy(image: p.provider.image, scale: p.provider.scale, to: p.pasteboard)
    }

    static func copy(fileURL: URL) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([fileURL as NSURL])
    }

    static func copy(text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    static func image() -> (CGImage, CGFloat)? {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let url = urls.first, let loaded = CGImage.load(from: url) {
            return (loaded.image, loaded.scale)
        }
        guard let image = NSImage(pasteboard: pb), let cg = image.cgImage else { return nil }
        let scale = max(1, (CGFloat(cg.width) / max(image.size.width, 1)).rounded())
        return (cg, scale)
    }
}

/// Supplies a promised image the first time an app pastes it.
final class LazyImageProvider: NSObject, NSPasteboardItemDataProvider {
    let image: CGImage
    let scale: CGFloat
    private let onPaste: @MainActor () -> Void
    private(set) var delivered = false

    init(image: CGImage, scale: CGFloat, onPaste: @escaping @MainActor () -> Void) {
        self.image = image
        self.scale = scale
        self.onPaste = onPaste
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        let data = type == .png ? image.encoded(as: .png, scale: scale) : image.nsImage(scale: scale).tiffRepresentation
        if let data { item.setData(data, forType: type) }
        guard !delivered else { return }
        delivered = true
        let callback = onPaste
        DispatchQueue.main.async { MainActor.assumeIsolated { callback() } }
    }
}
