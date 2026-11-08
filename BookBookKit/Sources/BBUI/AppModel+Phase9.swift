import BBAI
import BBAICore
import BBModel
import BBStore
import Foundation

// Phase 9 contract (main thread): the AppModel API the views use. Bodies are stubs until the
// wiring lane implements them; views lanes call only these.

/// "Draft all empty boxes" (PD §8.5): one Draft-quality item per image box with no image yet.
public struct DraftAllPlan: Sendable {
    /// Ready to enqueue (pending messages are appended only by `enqueueDraftAll`).
    public var items: [QueueItem]
    /// The page and box each item fills, parallel to `items`.
    public var targets: [(page: PageID, box: BoxID)]
    public var estimate: CostEstimate
    public var count: Int { items.count }

    public init(items: [QueueItem] = [], targets: [(page: PageID, box: BoxID)] = [],
                estimate: CostEstimate = CostEstimate(amount: 0)) {
        self.items = items
        self.targets = targets
        self.estimate = estimate
    }
}

public enum ConnectionTestResult: Sendable {
    /// The key works; `modelCount` models are listed.
    case success(modelCount: Int)
    case failure(FailureAdvice)
}

extension AppModel {
    // MARK: Cost (A §7.10)

    /// The estimate shown next to Generate. Sync: built from the document's current content.
    public func estimate(prompt: String, quality: QualityLevel, includeStoryText: Bool, refines: VersionID?,
                         page: PageID, box: BoxID, in document: BookDocument) -> CostEstimate {
        .unknown
    }

    /// Asks `CostPolicy` with the Settings threshold and the book's ledger total and budget.
    public func costDecision(for estimate: CostEstimate, in document: BookDocument) async -> CostDecision {
        CostDecision(needsConfirmation: false, overBudget: false)
    }

    /// The book's ledger totals (Book Settings → Cost, PD §8.12).
    public func ledgerSummary(for bookID: BookID) async -> LedgerSummary { LedgerSummary() }

    /// The ledger line for `Provenance.cost` (Version details).
    public func costRecord(_ id: CostRecordID, in bookID: BookID) async -> CostRecord? { nil }

    /// Not undoable (like the author). nil clears the budget.
    @discardableResult
    public func setBudget(_ budget: Decimal?, in document: BookDocument) -> Bool { false }

    // MARK: Draft all empty boxes (PD §8.5)

    public func draftAllPlan(in document: BookDocument) -> DraftAllPlan { DraftAllPlan() }

    /// Appends the pending messages and enqueues every item in one call. False if nothing was queued.
    @discardableResult
    public func enqueueDraftAll(_ plan: DraftAllPlan, in document: BookDocument) -> Bool { false }

    // MARK: Queue controls (A §7.9)

    public func resumeQueue() {}
    public func pauseQueue() {}
    public func moveQueueItem(_ id: QueueItemID, to index: Int) {}
    /// Waiting, retrying or failed items.
    public func removeQueueItem(_ id: QueueItemID) {}
    /// Callers show the "may still be billed" notice first (PD §5).
    public func cancelRunningItem() {}
    public func retryQueueItem(_ id: QueueItemID) {}

    /// Plain-language advice for a failed entry (A §7.11).
    public func advice(for entry: QueueEntry) -> FailureAdvice? { nil }

    // MARK: Settings (PD §8.11, A §7.1)

    /// Calls the provider's list-models endpoint with the stored key, updates
    /// `modelAvailability` and `missingDefaultModel`.
    public func testConnection(_ provider: ProviderID) async -> ConnectionTestResult {
        .failure(FailureAdvice(headline: "Not available yet", explanation: ""))
    }

    /// Image models for the Settings picker: bundled plus custom, current first.
    public func imageModels(for provider: ProviderID) -> [CatalogModel] { [] }

    /// Adds a custom model ID copying `family`; false if the family is unknown or the ID exists.
    @discardableResult
    public func addCustomModel(id: String, copying family: String, provider: ProviderID) -> Bool { false }
    public func removeCustomModel(_ spec: CustomModelSpec) {}
}
