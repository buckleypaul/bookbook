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
    /// Writing a new rendition deletes the older ones of the same source file and size (and any
    /// left in the old `<hash>.png` naming). Returns nil if `source` can't be read as an image.
    public func rendition(of source: URL, bookID: BookID, maxPixelSize: Int) -> URL? {
        // URL caches resource values per instance; a reused URL would hide a changed mtime.
        var source = source
        source.removeAllCachedResourceValues()
        guard maxPixelSize > 0,
              let values = try? source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize, let modified = values.contentModificationDate
        else { return nil }
        // Named `<group>-<version>.png`. The group hashes the source's full path and the size, so
        // two sources never share one (every library thumbnail is a `thumbnail.png`, and a Finder
        // copy of a book keeps its ID); the version also hashes the source's byte size and mtime,
        // so a changed source gets a new name (stale renditions are never served) and its older
        // versions share the group prefix.
        let path = source.standardizedFileURL.path(percentEncoded: false)
        let group = Self.digest("\(path)|\(maxPixelSize)", length: 16)
        let version = Self.digest("\(path)|\(size)|\(modified.timeIntervalSince1970)|\(maxPixelSize)", length: 32)
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

    /// Deletes the renditions in `directory` named `<group>-…`, except `kept`, and every
    /// rendition in the old `<hash>.png` naming (nothing returns those any more).
    private func removeRenditions(in directory: URL, group: String, keeping kept: String) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name != kept && (name.hasPrefix("\(group)-") || Self.isLegacyRendition(name)) {
            try? FileManager.default.removeItem(at: directory.appending(path: name, directoryHint: .notDirectory))
        }
    }

    /// A rendition named before groups: 32 lowercase hex digits, then `.png`.
    static func isLegacyRendition(_ name: String) -> Bool {
        guard name.hasSuffix(".png") else { return false }
        let stem = name.dropLast(4)
        return stem.count == 32 && stem.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
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
        let geometry = PageGeometry.drawGeometry(for: page, in: content)
        let trim = geometry.trimSize
        guard trim.width > 0, trim.height > 0 else { return nil }
        let scale = Double(maxPixelSize) / max(trim.width, trim.height)
        let width = max(1, Int((trim.width * scale).rounded()))
        let height = max(1, Int((trim.height * scale).rounded()))
        // Each placed image's box in output pixels, with its crop: the decode size is picked from these.
        let xScale = Double(width) / trim.width, yScale = Double(height) / trim.height
        var uses: [ImageRef: [PlacedImageSource.Use]] = [:]
        for box in content.template(for: page)?.imageBoxes ?? [] {
            guard let placement = page.images[box.id]?.placement,
                  let ref = content.placedVersion(page: page.id, box: box.id)?.image else { continue }
            let rect = geometry.renderRect(for: box)
            uses[ref, default: []].append(PlacedImageSource.Use(
                boxPixelSize: CGSize(width: rect.width * xScale, height: rect.height * yScale), placement: placement))
        }
        let image = withoutActuallyEscaping(imageURL) { escapable in
            ThumbnailRendering.render(page: page, in: content, trim: trim,
                                      pixelWidth: width, pixelHeight: height,
                                      images: PlacedImageSource(uses: uses, urlForRef: escapable),
                                      options: RenderOptions(target: .thumbnail))
        }
        return image.flatMap(ThumbnailRendering.pngData)
    }

    /// The page the thumbnail draws: the cover, or the first story page if there is none.
    static func page(in content: BookContent) -> Page? {
        content.coverPage ?? content.storyPages.first
    }
}

/// The library thumbnail's placed images, each decoded once for one render, downsampled only as
/// far as every box it fills keeps about one source pixel per output pixel (a zoomed-in crop
/// needs more of the image than the thumbnail's size; an aspect-fill crop at zoom 1 about the
/// box's size).
@MainActor
final class PlacedImageSource: PageImageSource {
    /// One box drawing the image: its size in output pixels and how the image sits in it.
    struct Use {
        var boxPixelSize: CGSize
        var placement: ImagePlacement
    }

    private let uses: [ImageRef: [Use]]
    private let urlForRef: (ImageRef) -> URL
    private var decoded: [ImageRef: CGImage] = [:]

    init(uses: [ImageRef: [Use]], urlForRef: @escaping (ImageRef) -> URL) {
        self.uses = uses
        self.urlForRef = urlForRef
    }

    func image(for ref: ImageRef) -> CGImage? {
        if let image = decoded[ref] { return image }
        guard let source = CGImageSourceCreateWithURL(urlForRef(ref) as CFURL,
                                                      [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        // An unreadable header decodes whole, as before downsampling.
        let maxPixelSize = ImageCache.orientedPixelSize(source).flatMap {
            Self.decodePixelSize(imageSize: $0, uses: uses[ref] ?? [])
        }
        guard let image = ImageCache.load(source, maxPixelSize: maxPixelSize) else { return nil }
        decoded[ref] = image
        return image
    }

    /// The longest side to decode an `imageSize` image at so that, drawn into each of `uses`
    /// (aspect-filled, zoomed and panned as `PageRenderer` draws it), it has at least one pixel
    /// per output pixel. Nil means full resolution: the image is no bigger than that.
    nonisolated static func decodePixelSize(imageSize: CGSize, uses: [Use]) -> Int? {
        guard imageSize.width > 0, imageSize.height > 0, !uses.isEmpty else { return nil }
        // The drawn rect's size depends only on the image's aspect, not its resolution.
        let needed = uses.map { use in
            let box = CGRect(origin: .zero, size: use.boxPixelSize)
            let drawn = PageGeometry.imageRect(imageSize: imageSize, boxRect: box, placement: use.placement)
            return max(drawn.width, drawn.height)
        }.max() ?? 0
        guard needed.isFinite, needed < max(imageSize.width, imageSize.height) else { return nil }
        return max(1, Int(needed.rounded(.up)))
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
