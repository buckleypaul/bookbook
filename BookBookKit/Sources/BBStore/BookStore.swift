import BBModel
import Foundation

// Owned by the Store lane. Contract stub: signatures are frozen, bodies are placeholders.

/// Serializes all I/O for one book package (A §5.1–5.3). One per open book.
public actor BookStore {
    public nonisolated let packageURL: URL

    public init(packageURL: URL) {
        self.packageURL = packageURL
    }

    /// Writes a new package at `url` (fails if it exists). One transaction.
    public static func create(_ content: BookContent, at url: URL) throws(StoreError) {
        fatalError("Phase 2 Store lane: not implemented")
    }

    /// Rolls a committed journal forward (or discards an uncommitted one), then reads the book.
    public func load() throws(StoreError) -> BookContent {
        fatalError("Phase 2 Store lane: not implemented")
    }

    /// Saves the dirty entities of `content` as one journaled transaction (A §5.2).
    public func save(_ content: BookContent, dirty: DirtySet) throws(StoreError) {
        fatalError("Phase 2 Store lane: not implemented")
    }

    /// Debounced autosave (1 s after the last call). Dirty sets accumulate; the content with the
    /// highest `generation` wins, so an out-of-order older snapshot is ignored.
    public func scheduleSave(_ content: BookContent, dirty: DirtySet, generation: Int) {
        fatalError("Phase 2 Store lane: not implemented")
    }

    /// Performs any pending scheduled save now (window close, quit, hide).
    public func flush() throws(StoreError) {
        fatalError("Phase 2 Store lane: not implemented")
    }

    /// Writes image bytes to `images/<sha256>.<ext>` (temp file + rename; idempotent) and
    /// returns the ref. Called before the JSON that refers to it is saved.
    public func storeImage(_ data: Data, contentType: String) throws(StoreError) -> ImageRef {
        fatalError("Phase 2 Store lane: not implemented")
    }

    /// Where an image file lives (it may not exist yet).
    public nonisolated func imageURL(for ref: ImageRef) -> URL {
        packageURL.appending(path: "images").appending(path: ref.fileName)
    }
}
