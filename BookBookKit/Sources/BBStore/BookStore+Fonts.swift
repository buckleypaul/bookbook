import BBModel
import Foundation

/// Imported fonts live in `fonts/<sha256>.<ext>` (A §5.1, §8.3). Importing a font isn't
/// undoable (PD §8.10) and isn't recorded in the model: every file in `fonts/` is registered
/// when the book opens. Phase 4 contract; lane C implements.
extension BookStore {
    /// Copies the font bytes into `fonts/` under their SHA-256 name (keeping the lowercased
    /// extension: ttf, otf or ttc), atomically. Storing the same bytes twice is a no-op.
    /// Returns the stored file's URL. Read-only stores throw `.readOnly`.
    public func storeFont(_ data: Data, fileExtension: String) throws(StoreError) -> URL {
        throw .io("not implemented")
    }

    /// Every font file in `fonts/` (ttf/otf/ttc), sorted by name. Empty if the folder is missing.
    public nonisolated func fontFileURLs() -> [URL] {
        []
    }
}
