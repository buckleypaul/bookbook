import Foundation
import BBModel
import Synchronization

/// Process-wide registry of image file names that the open-time image sweep
/// must keep for a book, even when no saved JSON references them yet
/// (for example a queued region edit's mask, or a refine base held by a
/// queued request). The queue file store fills it; `BookStore`'s sweep reads it.
public final class SweepProtection: Sendable {
    public static let shared = SweepProtection()

    private let state = Mutex<[BookID: Set<String>]>([:])

    public init() {}

    /// Replaces the protected file names for `book`. An empty set clears it.
    public func set(_ names: Set<String>, for book: BookID) {
        state.withLock { $0[book] = names.isEmpty ? nil : names }
    }

    /// The protected file names for `book` (empty when none).
    public func names(for book: BookID) -> Set<String> {
        state.withLock { $0[book] ?? [] }
    }
}
