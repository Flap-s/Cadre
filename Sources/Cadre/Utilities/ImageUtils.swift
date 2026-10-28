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
    static func copy(image: CGImage, scale: CGFloat) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let ns = image.nsImage(scale: scale)
        if let png = image.encoded(as: .png, scale: scale) { pb.setData(png, forType: .png) }
        if let tiff = ns.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
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
