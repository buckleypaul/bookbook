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
    /// Returns nil if `source` can't be read as an image.
    public func rendition(of source: URL, bookID: BookID, maxPixelSize: Int) -> URL? {
        // URL caches resource values per instance; a reused URL would hide a changed mtime.
        var source = source
        source.removeAllCachedResourceValues()
        guard maxPixelSize > 0,
              let values = try? source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize, let modified = values.contentModificationDate
        else { return nil }
        // A changed source (size or mtime) hashes to a new name, so stale renditions are never served.
        let key = "\(source.lastPathComponent)|\(size)|\(modified.timeIntervalSince1970)|\(maxPixelSize)"
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined().prefix(32)
        let directory = root.appending(path: bookID.rawValue.uuidString,directoryHint: .isDirectory)
        let output = directory.appending(path: "\(digest).png", directoryHint: .notDirectory)
        if FileManager.default.fileExists(atPath: output.path) { return output }

        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try (data as Data).write(to: output, options: .atomic)
        } catch {
            return nil
        }
        return output
    }

    /// Deletes `<root>/<bookID>/`.
    public func removeAll(for bookID: BookID) {
        try? FileManager.default.removeItem(at: root.appending(path: bookID.rawValue.uuidString, directoryHint: .isDirectory))
    }
}

/// Renders a book's library thumbnail (`thumbnail.png`, A §5.1). Thumbnail lane implements it.
@MainActor
public enum BookThumbnail {
    /// PNG of the cover page, or the first story page while the cover is hidden (until Phase 5),
    /// longest side `maxPixelSize`. Nil if the book has no pages.
    public static func png(for content: BookContent, imageURL: (ImageRef) -> URL, maxPixelSize: Int = 512) -> Data? {
        // The cover stays hidden until Phase 5, so the thumbnail is the first story page.
        guard maxPixelSize > 0, let page = content.storyPages.first else { return nil }
        let trim = content.style.pageSetup.trimSize
        guard trim.width > 0, trim.height > 0 else { return nil }
        let scale = Double(maxPixelSize) / max(trim.width, trim.height)
        let width = max(1, Int((trim.width * scale).rounded()))
        let height = max(1, Int((trim.height * scale).rounded()))
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // PageRenderer wants trim points, origin top-left, y down.
        ctx.translateBy(x: 0, y: Double(height))
        ctx.scaleBy(x: Double(width) / trim.width, y: -Double(height) / trim.height)
        withoutActuallyEscaping(imageURL) { escapable in
            let source = URLImageSource(imageURL: escapable)
            PageRenderer(images: source).draw(page: page, in: content, into: ctx, options: RenderOptions(target: .thumbnail))
        }
        guard let image = ctx.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

/// Decodes `ImageRef`s from file URLs for a single render.
@MainActor
private final class URLImageSource: PageImageSource {
    let imageURL: (ImageRef) -> URL
    init(imageURL: @escaping (ImageRef) -> URL) { self.imageURL = imageURL }

    func image(for ref: ImageRef) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(imageURL(ref) as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
