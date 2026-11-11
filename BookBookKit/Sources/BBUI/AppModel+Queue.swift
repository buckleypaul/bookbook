import BBAI
import BBAICore
import BBModel
import BBStore
import Foundation

// Queue controls (A §7.9).

extension AppModel {
    public func resumeQueue() {
        queueOperation { await $0.resume() }
    }

    public func pauseQueue() {
        queueOperation { await $0.pause() }
    }

    /// `index` is the destination among `queueSnapshot.entries` (`GenerationQueue.move`).
    public func moveQueueItem(_ id: QueueItemID, to index: Int) {
        queueOperation { await $0.move(id, to: index) }
    }

    /// Waiting, retrying or failed items.
    public func removeQueueItem(_ id: QueueItemID) {
        queueOperation { await $0.remove(id) }
    }

    /// Callers show the "may still be billed" notice first (PD §5).
    public func cancelRunningItem() {
        queueOperation { await $0.cancelRunning() }
    }

    public func retryQueueItem(_ id: QueueItemID) {
        queueOperation { await $0.retry(id) }
    }

    /// Plain-language advice for a failed entry (A §7.11).
    public func advice(for entry: QueueEntry) -> FailureAdvice? {
        guard case let .failed(failure) = entry.state else { return nil }
        return RefusalAdvisor.advise(failure.error,
                                     context: AdviceContext(provider: entry.item.intent.provider, report: failure.report))
    }
}
