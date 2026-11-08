import BBModel
import Foundation

// Phase 3 contract (main thread). The thumbnail lane implements it.

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
    public func rendition(of source: URL, bookID: BookID, maxPixelSize: Int) -> URL? { nil }

    /// Deletes `<root>/<bookID>/`.
    public func removeAll(for bookID: BookID) {}
}

/// Renders a book's library thumbnail (`thumbnail.png`, A §5.1). Thumbnail lane implements it.
@MainActor
public enum BookThumbnail {
    /// PNG of the cover page, or the first story page while the cover is hidden (until Phase 5),
    /// longest side `maxPixelSize`. Nil if the book has no pages.
    public static func png(for content: BookContent, imageURL: (ImageRef) -> URL, maxPixelSize: Int = 512) -> Data? {
        nil
    }
}
