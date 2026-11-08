import BBAI
import BBAICore
import BBModel
import BBStore
import Foundation

/// The queue's host (A §6.4). Every delivery goes through `OpenBooks` on the main actor, which
/// serializes it with opening and closing that book.
public struct BookWriter: GenerationHost {
    let openBooks: OpenBooks
    let now: @Sendable () -> Date

    public init(openBooks: OpenBooks, now: @escaping @Sendable () -> Date = { Date() }) {
        self.openBooks = openBooks
        self.now = now
    }

    public func content(for bookID: BookID) async -> BookContent? {
        await openBooks.content(for: bookID)
    }

    // Phase 9 contract stub: the wiring lane returns the real result from OpenBooks.
    public func deliver(_ delivery: GenerationDelivery) async -> DeliveryResult {
        await openBooks.deliver(delivery, now: now)
        return .delivered
    }

    /// Image files are immutable and content-addressed, so they're read without the book lock.
    public func imageData(for ref: ImageRef, in bookID: BookID) async -> Data? {
        guard let url = await openBooks.packageURL(for: bookID) else { return nil }
        let fileURL = BookStore(packageURL: url).imageURL(for: ref)
        return try? Data(contentsOf: fileURL, options: .mappedIfSafe)
    }
}
