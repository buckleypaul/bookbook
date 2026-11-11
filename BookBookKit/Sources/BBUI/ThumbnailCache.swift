import BBLayout
import BBModel
import CryptoKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Downsampled renditions of package images, in `~/Library/Caches/BookBook/<bookID>/` (A §5.1, §6.5).
/// Never stored in the package; rebuilt when missing or when the source file changes.
public actor ThumbnailCache {
    public nonisolated let root: URL

    /// `~/Library/Caches/BookBook/`.
    public static var defaultRoot: URL {
        URL.cachesDirectory.appending(path: "BookBook", directoryHint: .isDirectory)
    }

    public init(root: URL = ThumbnailCache.defaultRoot) {
        self.root = root
    }

    /// A PNG of `source` with its longest side at most `maxPixelSize`, cached under `<root>/<bookID>/`.
    /// Writing a new rendition deletes the older ones of the same source and size. Returns nil if
    /// `source` can't be read as an image.
    public func rendition(of source: URL, bookID: BookID, maxPixelSize: Int) -> URL? {
        // URL caches resource values per instance; a reused URL would hide a changed mtime.
        var source = source
        source.removeAllCachedResourceValues()
        guard maxPixelSize > 0,
              let values = try? source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize, let modified = values.contentModificationDate
        else { return nil }
        // Named `<group>-<version>.png`. The group hashes the source's name and the size; the
        // version also hashes the source's byte size and mtime, so a changed source gets a new
        // name (stale renditions are never served) and its older versions share the group prefix.
        let group = Self.digest("\(source.lastPathComponent)|\(maxPixelSize)", length: 16)
        let version = Self.digest(
            "\(source.lastPathComponent)|\(size)|\(modified.timeIntervalSince1970)|\(maxPixelSize)", length: 32)
        let name = "\(group)-\(version).png"
        let directory = root.appending(path: bookID.rawValue.uuidString, directoryHint: .isDirectory)
        let output = directory.appending(path: name, directoryHint: .notDirectory)
        if FileManager.default.fileExists(atPath: output.path) { return output }

        guard let image = ImageCache.load(source, maxPixelSize: maxPixelSize),
              let data = ThumbnailRendering.pngData(image) else { return nil }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: output, options: .atomic)
        } catch {
            return nil
        }
        removeRenditions(in: directory, group: group, keeping: name)
        return output
    }

    /// Deletes `<root>/<bookID>/`.
    public func removeAll(for bookID: BookID) {
        try? FileManager.default.removeItem(at: root.appending(path: bookID.rawValue.uuidString, directoryHint: .isDirectory))
    }

    /// Deletes the renditions in `directory` named `<group>-…`, except `kept`.
    private func removeRenditions(in directory: URL, group: String, keeping kept: String) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name != kept && name.hasPrefix("\(group)-") {
            try? FileManager.default.removeItem(at: directory.appending(path: name, directoryHint: .notDirectory))
        }
    }

    /// The first `length` hex digits of the SHA-256 of `key`.
    private static func digest(_ key: String, length: Int) -> String {
        String(SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined().prefix(length))
    }
}

/// Renders a book's library thumbnail (`thumbnail.png`, A §5.1). Thumbnail lane implements it.
@MainActor
public enum BookThumbnail {
    /// PNG of the cover page, or the first story page if there is none,
    /// longest side `maxPixelSize`. Nil if the book has no pages.
    public static func png(for content: BookContent, imageURL: (ImageRef) -> URL, maxPixelSize: Int = 512) -> Data? {
        guard maxPixelSize > 0, let page = page(in: content) else { return nil }
        // A spread (a book without a cover) is drawn whole, at double width.
        let trim = PageGeometry.drawGeometry(for: page, in: content).trimSize
        guard trim.width > 0, trim.height > 0 else { return nil }
        let scale = Double(maxPixelSize) / max(trim.width, trim.height)
        let width = max(1, Int((trim.width * scale).rounded()))
        let height = max(1, Int((trim.height * scale).rounded()))
        let image = withoutActuallyEscaping(imageURL) { escapable in
            // Placed images are decoded downsampled, to twice the thumbnail's longest side, so an
            // aspect-filled or zoomed-in image still has about a pixel per output pixel. The cache
            // lives for this one render.
            ThumbnailRendering.render(page: page, in: content, trim: trim,
                                      pixelWidth: width, pixelHeight: height,
                                      images: ImageCache(maxPixelSize: maxPixelSize * 2, urlForRef: escapable),
                                      options: RenderOptions(target: .thumbnail))
        }
        return image.flatMap(ThumbnailRendering.pngData)
    }

    /// The page the thumbnail draws: the cover, or the first story page if there is none.
    static func page(in content: BookContent) -> Page? {
        content.coverPage ?? content.storyPages.first
    }
}

/// The bitmap set-up and PNG encoding shared by the library and Pages-overview thumbnails.
enum ThumbnailRendering {
    /// Draws `page` of `content` (its draw trim is `trim` points, double width for a spread) into a new
    /// `pixelWidth`×`pixelHeight` sRGB bitmap. `fillWhite` paints the bitmap white first.
    /// `layouts` reuses text layouts across renders.
    @MainActor
    static func render(page: Page, in content: BookContent, trim: CGSize, pixelWidth: Int, pixelHeight: Int,
                       images: any PageImageSource, layouts: TextBoxLayoutCache? = nil, options: RenderOptions,
                       fillWhite: Bool = false) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        if fillWhite {
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        }
        // PageRenderer wants trim points, origin top-left, y down.
        ctx.translateBy(x: 0, y: Double(pixelHeight))
        ctx.scaleBy(x: Double(pixelWidth) / trim.width, y: -Double(pixelHeight) / trim.height)
        var renderer = PageRenderer(images: images)
        renderer.layouts = layouts
        renderer.draw(page: page, in: content, into: ctx, options: options)
        return ctx.makeImage()
    }

    /// `image` encoded as PNG.
    static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
