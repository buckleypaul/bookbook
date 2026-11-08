import BBAI
import BBAICore
import BBModel
import BBStore
import Foundation
import Observation
import os

/// The registry of open books, `BookID → BookDocument` (A §6.1), plus the library's
/// `BookID → URL` lookup from the last `Library.scan()`.
///
/// It is also the one place queue results are written (A §6.4). Per book, opening, closing and
/// delivering run one at a time, so:
/// - `open` waits for a delivery that is writing to the closed book on disk;
/// - a delivery that arrives while the book is closing waits for the close, then writes to disk;
/// - a delivery to an open book is applied before any later close flushes it.
@MainActor @Observable
public final class OpenBooks {
    public private(set) var documents: [BookID: BookDocument] = [:]
    @ObservationIgnored private var closing: Set<BookID> = []
    @ObservationIgnored private var tails: [BookID: Task<Void, Never>] = [:]
    @ObservationIgnored private var urls: [BookID: URL] = [:]
    @ObservationIgnored public let library: Library
    /// Called when a finished picture couldn't be written into its book.
    @ObservationIgnored public var onDeliveryProblem: (MessageID, String) -> Void = { _, _ in }

    private static let log = Logger(subsystem: "app.bookbook", category: "OpenBooks")

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

    // MARK: Per-book serialization

    /// Runs `operation` after every earlier operation on the same book has finished.
    private func serialized<T: Sendable>(_ id: BookID, _ operation: @escaping @MainActor () async -> T) async -> T {
        let previous = tails[id]
        let task = Task { @MainActor in
            await previous?.value
            return await operation()
        }
        let tail = Task<Void, Never> { _ = await task.value }
        tails[id] = tail
        let result = await task.value
        if tails[id] == tail { tails[id] = nil }
        return result
    }

    // MARK: Open and close

    /// Opens a book, or returns it if it's already open.
    public func open(_ id: BookID) async throws -> BookDocument {
        if let document = documents[id], !closing.contains(id) { return document }
        let result: Result<BookDocument, any Error> = await serialized(id) { [self] in
            if let document = documents[id] { return .success(document) }
            guard let url = await packageURL(for: id) else { return .failure(StoreError.notFound("book \(id)")) }
            do {
                let document = try await BookDocument.open(at: url)
                documents[id] = document
                return .success(document)
            } catch {
                return .failure(error)
            }
        }
        return try result.get()
    }

    /// Flushes and forgets a book (its window closed). Deliveries arriving meanwhile wait, then
    /// go to the package on disk.
    public func close(_ id: BookID) async {
        guard documents[id] != nil else { return }
        closing.insert(id)
        await serialized(id) { [self] in
            if let document = documents[id] {
                await document.flush()
                documents[id] = nil
            }
            closing.remove(id)
        }
    }

    /// Writes every open book's pending autosave (quit, hide).
    public func flushAll() async {
        for document in documents.values { await document.flush() }
    }

    // MARK: Deliveries (A §6.4)

    /// A snapshot of the book for context assembly: the open document, else the package on disk.
    public func content(for id: BookID) async -> BookContent? {
        if let document = documents[id] { return document.content }
        guard let url = await packageURL(for: id) else { return nil }
        return try? await BookStore(packageURL: url).load()
    }

    /// Writes a finished generation into its book, open or closed. The image file is always
    /// written before the session JSON that refers to it (A §5.2).
    public func deliver(_ delivery: GenerationDelivery, now: @escaping @Sendable () -> Date) async {
        let id = delivery.item.bookID
        await serialized(id) { [self] in
            if let store = documents[id]?.store {
                let ref = await storeImage(of: delivery, in: store)
                // Re-resolve by ID after the await (the close is serialized behind us, but be safe).
                if let document = documents[id] {
                    document.performIrreversible { content in
                        BookMutations.applyDelivery(delivery, storedImage: ref, to: &content, now: now())
                    }
                    return
                }
            }
            await deliverToClosedBook(delivery, now: now)
        }
    }

    private func deliverToClosedBook(_ delivery: GenerationDelivery, now: @Sendable () -> Date) async {
        guard let url = await packageURL(for: delivery.item.bookID) else {
            Self.log.notice("Dropped a delivery: the book is no longer in the library")
            report(delivery, "the book is no longer in the library.")
            return
        }
        let store = BookStore(packageURL: url)
        do {
            var content = try await store.load()
            let ref = await storeImage(of: delivery, in: store)
            var dirty = BookMutations.applyDelivery(delivery, storedImage: ref, to: &content, now: now())
            guard !dirty.isEmpty else { return }
            content.book.modifiedAt = now()
            dirty.book = true
            try await store.save(content, dirty: dirty)
        } catch {
            Self.log.error("Couldn't write a delivery to a closed book: \(String(describing: error), privacy: .public)")
            report(delivery, StoreErrorText.message(for: error))
        }
    }

    /// Stores the image of a successful delivery; nil for failures or if the write failed (the
    /// problem is reported so the paid result doesn't vanish silently).
    private func storeImage(of delivery: GenerationDelivery, in store: BookStore) async -> ImageRef? {
        guard case let .success(result, _) = delivery.outcome else { return nil }
        do {
            return try await store.storeImage(result.imageData, contentType: result.contentType)
        } catch {
            Self.log.error("Couldn't store a generated image: \(String(describing: error), privacy: .public)")
            report(delivery, StoreErrorText.message(for: error))
            return nil
        }
    }

    private func report(_ delivery: GenerationDelivery, _ reason: String) {
        guard case .success = delivery.outcome else { return }
        onDeliveryProblem(delivery.item.messageID, "Couldn't save the picture to the book: \(reason)")
    }
}
