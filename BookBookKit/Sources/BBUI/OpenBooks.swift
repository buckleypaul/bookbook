import BBModel
import BBStore
import Foundation
import Observation

/// The registry of open books, `BookID → BookDocument` (A §6.1), plus the library's
/// `BookID → URL` lookup from the last `Library.scan()`.
@MainActor @Observable
public final class OpenBooks {
    public private(set) var documents: [BookID: BookDocument] = [:]
    @ObservationIgnored private var opening: [BookID: Task<BookDocument, any Error>] = [:]
    @ObservationIgnored private var urls: [BookID: URL] = [:]
    @ObservationIgnored public let library: Library

    public init(library: Library) {
        self.library = library
    }

    public func document(for id: BookID) -> BookDocument? { documents[id] }

    /// Records where books live (from a library scan).
    public func remember(_ entries: [LibraryEntry]) {
        for entry in entries { urls[entry.id] = entry.url }
    }

    /// The package URL for a book, rescanning the library if it isn't known yet.
    public func packageURL(for id: BookID) async -> URL? {
        if let url = urls[id] { return url }
        let library = library
        let entries = await Task.detached { library.scan() }.value
        remember(entries)
        return urls[id]
    }

    /// Opens a book, or returns it if it's already open (or opening).
    public func open(_ id: BookID) async throws -> BookDocument {
        if let document = documents[id] { return document }
        if let task = opening[id] { return try await task.value }
        let task = Task<BookDocument, any Error> {
            guard let url = await packageURL(for: id) else { throw StoreError.notFound("book \(id)") }
            return try await BookDocument.open(at: url)
        }
        opening[id] = task
        defer { opening[id] = nil }
        let document = try await task.value
        documents[id] = document
        return document
    }

    /// Flushes and forgets a book (its window closed). The document stays registered until the
    /// flush finishes, so a delivery arriving meanwhile still goes to it.
    public func close(_ id: BookID) async {
        guard let document = documents[id] else { return }
        await document.flush()
        if documents[id] === document { documents[id] = nil }
    }

    /// Writes every open book's pending autosave (quit, hide).
    public func flushAll() async {
        for document in documents.values { await document.flush() }
    }
}
