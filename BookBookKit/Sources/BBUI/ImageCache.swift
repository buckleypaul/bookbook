import BBLayout
import BBModel
import BBStore
import CoreGraphics
import Foundation
import ImageIO

/// Loads a book's images from `store.imageURL(for:)` with ImageIO (A §6.2: the canvas draws
/// downsampled images; export uses full-resolution files). A small in-memory cache per window;
/// past `capacity`, the least recently used image is dropped.
@MainActor
public final class ImageCache: PageImageSource {
    /// Longest side of a `previews` image, in pixels.
    public static let previewPixelSize = 256

    /// Longest side for the screen; nil = full resolution (export).
    public let maxPixelSize: Int?
    private let urlForRef: (ImageRef) -> URL
    /// Each cached image with the tick of its last use; the smallest tick is evicted first.
    private var cache: [ImageRef: (image: CGImage, lastUse: UInt64)] = [:]
    private var clock: UInt64 = 0
    private let capacity: Int

    /// A companion cache of small images (`previewPixelSize` on the longest side) for list rows
    /// and small thumbnails, so they don't push this cache's larger images out. Same files;
    /// made on first use.
    public private(set) lazy var previews = ImageCache(maxPixelSize: Self.previewPixelSize, capacity: 64,
                                                       urlForRef: urlForRef)

    public init(maxPixelSize: Int? = 2048, capacity: Int = 32, urlForRef: @escaping (ImageRef) -> URL) {
        self.maxPixelSize = maxPixelSize
        self.capacity = capacity
        self.urlForRef = urlForRef
    }

    public convenience init(store: BookStore, maxPixelSize: Int? = 2048) {
        self.init(maxPixelSize: maxPixelSize) { store.imageURL(for: $0) }
    }

    public func image(for ref: ImageRef) -> CGImage? {
        clock &+= 1
        // A hit only bumps its tick (O(1)); the canvas asks for every image box on every draw.
        if let image = cache[ref]?.image {
            cache[ref]?.lastUse = clock
            return image
        }
        // A miss isn't cached: the file may be written a moment later.
        guard let image = Self.load(urlForRef(ref), maxPixelSize: maxPixelSize) else { return nil }
        cache[ref] = (image, clock)
        if cache.count > capacity, let oldest = cache.min(by: { $0.value.lastUse < $1.value.lastUse })?.key {
            cache[oldest] = nil
        }
        return image
    }

    /// Decodes the image at `url`, downsampled to `maxPixelSize` on its longest side (nil = full
    /// resolution). Safe off the main actor.
    nonisolated static func load(_ url: URL, maxPixelSize: Int?) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        return load(source, maxPixelSize: maxPixelSize)
    }

    /// `load(_:maxPixelSize:)` for in-memory image `data`.
    nonisolated static func load(_ data: Data, maxPixelSize: Int?) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return load(source, maxPixelSize: maxPixelSize)
    }

    /// The first image of `source`: whole, or a thumbnail (orientation applied) at most
    /// `maxPixelSize` on its longest side.
    nonisolated private static func load(_ source: CGImageSource, maxPixelSize: Int?) -> CGImage? {
        guard let maxPixelSize else {
            return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
