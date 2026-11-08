import BBAICore
import BBModel
import Foundation

// Owned by the AI lane. Contract stub: signatures are frozen, bodies are placeholders.

/// App-wide serial queue, v0 (plan P-4, A §7.9): in memory, one item at a time, no retries,
/// no persistence or reordering (Phase 9).
public actor GenerationQueue {
    public init(providers: [ProviderID: any ImageProvider], catalog: ModelCatalog, host: any GenerationHost,
                now: @escaping @Sendable () -> Date = { Date() }) {
        fatalError("Phase 2 AI lane: not implemented")
    }

    /// Appends an item; starts it if nothing is running.
    public func enqueue(_ item: QueueItem) {
        fatalError("Phase 2 AI lane: not implemented")
    }

    /// Cancels the running item (its delivery is `.failure(.cancelled)`).
    public func cancelRunning() {
        fatalError("Phase 2 AI lane: not implemented")
    }

    /// Removes a waiting or failed item. Does nothing for the running item.
    public func remove(_ id: QueueItemID) {
        fatalError("Phase 2 AI lane: not implemented")
    }

    public func snapshot() -> QueueSnapshot {
        fatalError("Phase 2 AI lane: not implemented")
    }

    /// A new stream per subscriber. Yields the current snapshot first, then every change.
    public func subscribe() -> AsyncStream<QueueSnapshot> {
        fatalError("Phase 2 AI lane: not implemented")
    }
}
