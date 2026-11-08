import Foundation

/// Identifies a book (architecture.md §4). Minimal for Phase 1b; grows with the model.
public struct BookID: Hashable, Codable, Sendable {
    public var rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}
