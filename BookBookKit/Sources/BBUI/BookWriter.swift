import BBAI
import BBAICore
import BBModel
import BBStore
import Foundation
import os

/// Writes queue results into books, open or closed (A §6.4). The image file is always written
/// before the session JSON that refers to it (A §5.2).
public struct BookWriter: GenerationHost {
    let openBooks: OpenBooks
    let now: @Sendable () -> Date

    private static let log = Logger(subsystem: "app.bookbook", category: "BookWriter")

    public init(openBooks: OpenBooks, now: @escaping @Sendable () -> Date = { Date() }) {
        self.openBooks = openBooks
        self.now = now
    }

    public func content(for bookID: BookID) async -> BookContent? {
        let openBooks = openBooks
        if let content = await MainActor.run(body: { openBooks.document(for: bookID)?.content }) {
            return content
        }
        guard let url = await openBooks.packageURL(for: bookID) else { return nil }
        return try? await BookStore(packageURL: url).load()
    }

    public func deliver(_ delivery: GenerationDelivery) async {
        let openBooks = openBooks, bookID = delivery.item.bookID, now = now
        let open = await MainActor.run { () -> (BookDocument, BookStore)? in
            guard let document = openBooks.document(for: bookID) else { return nil }
            return (document, document.store)
        }

        if let (document, store) = open {
            let ref = await Self.storeImage(of: delivery, in: store)
            await MainActor.run {
                document.performIrreversible { content in
                    BookMutations.applyDelivery(delivery, storedImage: ref, to: &content, now: now())
                }
            }
            return
        }

        // Closed book: a headless store, one transaction.
        guard let url = await openBooks.packageURL(for: bookID) else {
            Self.log.notice("Dropped a delivery: the book is no longer in the library")
            return
        }
        let store = BookStore(packageURL: url)
        do {
            var content = try await store.load()
            let ref = await Self.storeImage(of: delivery, in: store)
            var dirty = BookMutations.applyDelivery(delivery, storedImage: ref, to: &content, now: now())
            guard !dirty.isEmpty else { return }
            content.book.modifiedAt = now()
            dirty.book = true
            try await store.save(content, dirty: dirty)
        } catch {
            Self.log.error("Couldn't write a delivery to a closed book: \(String(describing: error), privacy: .public)")
        }
    }

    /// Stores the image of a successful delivery; nil for failures or if the write failed.
    private static func storeImage(of delivery: GenerationDelivery, in store: BookStore) async -> ImageRef? {
        guard case let .success(result, _) = delivery.outcome else { return nil }
        do {
            return try await store.storeImage(result.imageData, contentType: result.contentType)
        } catch {
            log.error("Couldn't store a generated image: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
