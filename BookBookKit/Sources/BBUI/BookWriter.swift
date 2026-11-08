import BBAI
import BBAICore
import BBModel
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

    public func deliver(_ delivery: GenerationDelivery) async {
        await openBooks.deliver(delivery, now: now)
    }
}
