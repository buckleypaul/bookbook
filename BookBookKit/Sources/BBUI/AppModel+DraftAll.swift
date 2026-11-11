import BBAI
import BBAICore
import BBModel
import BBStore
import Foundation

/// "Draft all empty boxes" (PD §8.5): one Draft-quality item per image box with no image yet.
public struct DraftAllPlan: Sendable {
    /// Ready to enqueue (pending messages are appended only by `enqueueDraftAll`).
    public var items: [QueueItem]
    public var estimate: CostEstimate
    public var count: Int { items.count }

    /// The page and box each item fills, in `items` order.
    public var targets: [(page: PageID, box: BoxID)] {
        items.compactMap { item in
            if case let .pageBox(page, box) = item.target { (page, box) } else { nil }
        }
    }

    public init(items: [QueueItem] = [], estimate: CostEstimate = CostEstimate(amount: 0)) {
        self.items = items
        self.estimate = estimate
    }
}

extension AppModel {
    /// One Draft-quality item (story text on) per image box with no placed image and nothing
    /// pending, with the combined estimate. Nothing is appended or enqueued yet.
    public func draftAllPlan(in document: BookDocument) -> DraftAllPlan {
        let content = document.content
        let settings = defaults
        let targets = DraftAllPlanner.emptyTargets(in: content) { isPending($0) }
        let items = targets.map { target in
            let intent = GenerationIntent(messageText: DraftAllPlanner.messageText, provider: settings.provider,
                                          model: settings.model, quality: .draft, includeStoryText: true)
            let item = QueueItem(bookID: document.id, target: .pageBox(target.page, target.box),
                                 messageID: MessageID(), intent: intent)
            return prepared(item, content: content)
        }
        return DraftAllPlan(items: items, estimate: CostEstimate.total(items.map(\.estimateIncludingFollowUp)))
    }

    /// Appends the pending messages and enqueues every item in one call. False if nothing was queued.
    /// Boxes filled (or already drafted from this plan) since the plan was made are skipped.
    @discardableResult
    public func enqueueDraftAll(_ plan: DraftAllPlan, in document: BookDocument) -> Bool {
        guard !plan.items.isEmpty else { return false }
        var queued: [QueueItem] = []
        document.performIrreversible { content in
            var dirty = DirtySet()
            for item in plan.items {
                guard case let .pageBox(page, box) = item.target, content.pages[page]?.images[box]?.placement == nil,
                      content.session(containing: item.messageID) == nil else { continue }
                let message = Message(id: item.messageID, role: .user, text: item.intent.messageText,
                                      queueItemID: item.id, createdAt: item.enqueuedAt)
                let changed = BookMutations.appendPendingMessage(message, target: item.target, to: &content)
                guard !changed.isEmpty else { continue }
                dirty.formUnion(changed)
                queued.append(item)
            }
            return dirty
        }
        guard !queued.isEmpty else { return false }
        notePending(queued.map(\.id))
        let enqueued = queued
        queueOperation { await $0.enqueue(enqueued, position: .end) }
        return true
    }
}
