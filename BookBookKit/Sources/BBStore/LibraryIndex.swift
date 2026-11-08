import BBModel
import Foundation

// Phase 3 contract (main thread). The library-index lane implements it.

/// The library folder's books, cached on disk and kept fresh with FSEvents (A §5.4).
public actor LibraryIndex {
    public nonisolated let root: URL
    public nonisolated let cacheURL: URL

    /// `~/Library/Application Support/BookBook/library-index.json`.
    public static var defaultCacheURL: URL {
        URL.applicationSupportDirectory.appending(path: "BookBook/library-index.json", directoryHint: .notDirectory)
    }

    public init(root: URL, cacheURL: URL = LibraryIndex.defaultCacheURL) {
        self.root = root
        self.cacheURL = cacheURL
    }

    /// The current entries, newest first. Empty until `loadCache()` or `refresh()`.
    public var entries: [LibraryEntry] { [] }

    /// Reads the cached index (ignored if it was written for another root). Fast; for first paint.
    @discardableResult
    public func loadCache() -> [LibraryEntry] { [] }

    /// Rescans the folder (`*.bookbook`, `book.json`, `thumbnail.png`), updates `entries` and rewrites the cache.
    @discardableResult
    public func refresh() -> [LibraryEntry] { [] }

    public func entry(for id: BookID) -> LibraryEntry? { nil }

    /// Starts watching the folder (once) and returns a stream that yields fresh entries after each debounced change.
    /// Noise from the app's own saves inside packages is filtered (changes to `book.json` and `thumbnail.png` still count).
    public func changes() -> AsyncStream<[LibraryEntry]> {
        AsyncStream { $0.finish() }
    }

    /// Stops watching and finishes every stream from `changes()`.
    public func stopWatching() {}
}
