import BBModel
import Foundation

// Owned by the Store lane. Contract stub: signatures are frozen, bodies are placeholders.

/// The library folder: a scan plus create (Phase 2; the index and FSEvents come in Phase 3).
public struct Library: Sendable {
    public var root: URL

    public init(root: URL = Library.defaultRoot) {
        self.root = root
    }

    /// `~/Library/Application Support/BookBook/Library/` (A §5.4).
    public static var defaultRoot: URL {
        URL.applicationSupportDirectory.appending(path: "BookBook/Library", directoryHint: .isDirectory)
    }

    /// Every readable `*.bookbook` in `root`, newest first. Unreadable packages are skipped.
    public func scan() -> [LibraryEntry] {
        fatalError("Phase 2 Store lane: not implemented")
    }

    /// Creates `<title>.bookbook` (a unique name if taken) from the built-in presets, with one
    /// story page (decided 2026-11-08), creating `root` if needed.
    public func createBook(title: String, now: Date = Date()) throws(StoreError) -> LibraryEntry {
        fatalError("Phase 2 Store lane: not implemented")
    }
}
