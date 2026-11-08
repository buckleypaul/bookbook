import BBLayout
import BBModel
import BBStore
import CoreGraphics
import Foundation
import ImageIO

/// Loads a book's images from `store.imageURL(for:)` with ImageIO (A §6.2: the canvas draws
/// downsampled images; export uses full-resolution files). A small in-memory cache per window.
@MainActor
public final class ImageCache: PageImageSource {
    /// Longest side for the screen; nil = full resolution (export).
    public let maxPixelSize: Int?
    private let urlForRef: (ImageRef) -> URL
    private var cache: [ImageRef: CGImage] = [:]
    private var order: [ImageRef] = []
    private let capacity: Int

    public init(maxPixelSize: Int? = 2048, capacity: Int = 32, urlForRef: @escaping (ImageRef) -> URL) {
        self.maxPixelSize = maxPixelSize
        self.capacity = capacity
        self.urlForRef = urlForRef
    }

    public convenience init(store: BookStore, maxPixelSize: Int? = 2048) {
        self.init(maxPixelSize: maxPixelSize) { store.imageURL(for: $0) }
    }

    public func image(for ref: ImageRef) -> CGImage? {
        if let image = cache[ref] { return image }
        // A miss isn't cached: the file may be written a moment later.
        guard let image = Self.load(urlForRef(ref), maxPixelSize: maxPixelSize) else { return nil }
        cache[ref] = image
        order.append(ref)
        if order.count > capacity { cache[order.removeFirst()] = nil }
        return image
    }

    static func load(_ url: URL, maxPixelSize: Int?) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
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
