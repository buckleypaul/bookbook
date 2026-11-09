import BBAI
import BBAICore
import BBModel
import BBStore
import Foundation

// Phase 9: the AppModel API the views use (contract by the main thread, wired here).

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
        let settings = defaults
        let intent = GenerationIntent(messageText: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                                      refines: refines, provider: settings.provider, model: settings.model,
                                      quality: quality, includeStoryText: includeStoryText)
        return estimate(intent, target: .pageBox(page, box), content: document.content)
    }

    /// The estimate for "Regenerate with same settings": the version's stored intent, unchanged.
    /// nil for a version with no provenance.
    public func regenerateEstimate(_ version: Version, page: PageID, box: BoxID, in document: BookDocument) -> CostEstimate? {
        guard let intent = (version.provenance?.intent).map(replayed) else { return nil }
        return estimate(intent, target: .pageBox(page, box), content: document.content)
    }

    /// Asks `CostPolicy` with the Settings threshold and the book's ledger total and budget.
    public func costDecision(for estimate: CostEstimate, in document: BookDocument) async -> CostDecision {
        let total = await ledgerSummary(for: document.id).total
        return CostPolicy.decide(estimate: estimate, threshold: preferences.confirmThreshold, bookTotal: total,
                                 budget: document.content.book.budget)
    }

    /// The book's ledger totals (Book Settings → Cost, PD §8.12). Read off the main actor.
    public func ledgerSummary(for bookID: BookID) async -> LedgerSummary {
        let read = await openBooks.costLedgerRead(for: bookID)
        return LedgerSummary(records: read.records, skippedLines: read.skipped)
    }

    /// The ledger line for `Provenance.cost` (Version details).
    public func costRecord(_ id: CostRecordID, in bookID: BookID) async -> CostRecord? {
        await openBooks.costRecords(for: bookID).last { $0.id == id }
    }

    /// Not undoable (like the author). nil clears the budget.
    @discardableResult
    public func setBudget(_ budget: Decimal?, in document: BookDocument) -> Bool {
        document.setBudget(budget)
    }

    // MARK: Draft all empty boxes (PD §8.5)

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
        return DraftAllPlan(items: items, targets: targets, estimate: CostEstimate.total(items.map(\.estimateIncludingFollowUp)))
    }

    /// Appends the pending messages and enqueues every item in one call. False if nothing was queued.
    /// Boxes filled (or already drafted from this plan) since the plan was made are skipped.
    @discardableResult
    public func enqueueDraftAll(_ plan: DraftAllPlan, in document: BookDocument) -> Bool {
        guard !plan.items.isEmpty, plan.items.count == plan.targets.count else { return false }
        var queued: [QueueItem] = []
        document.performIrreversible { content in
            var dirty = DirtySet()
            for (item, target) in zip(plan.items, plan.targets) {
                guard content.pages[target.page]?.images[target.box]?.placement == nil,
                      content.session(containing: item.messageID) == nil else { continue }
                let message = Message(id: item.messageID, role: .user, text: item.intent.messageText,
                                      queueItemID: item.id, createdAt: item.enqueuedAt)
                let changed = BookMutations.appendPendingMessage(message, page: target.page, box: target.box,
                                                                 to: &content)
                guard !changed.isEmpty else { continue }
                dirty.formUnion(changed)
                queued.append(item)
            }
            return dirty
        }
        guard !queued.isEmpty else { return false }
        notePending(queued.map(\.id))
        let items = queued
        queueOperation { await $0.enqueue(items, position: .end) }
        return true
    }

    // MARK: Queue controls (A §7.9)

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

    // MARK: Settings (PD §8.11, A §7.1)

    /// Calls the provider's list-models endpoint with the stored key, updates
    /// `modelAvailability` and `missingDefaultModel`. Concurrent calls share one request.
    public func testConnection(_ provider: ProviderID) async -> ConnectionTestResult {
        if let running = connectionTests[provider] { return await running.value }
        let task = Task { [weak self] () -> ConnectionTestResult in
            guard let self else { return .failure(FailureAdvice(headline: "Couldn't test the connection", explanation: "")) }
            return await self.runConnectionTest(provider)
        }
        connectionTests[provider] = task
        let result = await task.value
        if connectionTests[provider] == task { connectionTests[provider] = nil }
        return result
    }

    private func runConnectionTest(_ provider: ProviderID) async -> ConnectionTestResult {
        guard let lister = listers[provider] else {
            return .failure(FailureAdvice(headline: "Can't test this provider yet",
                                          explanation: "BookBook can't check this provider's models."))
        }
        do throws(ProviderError) {
            let ids = try await lister.listModelIDs()
            listedModels[provider] = ids
            refreshAvailability()
            return .success(modelCount: ids.count)
        } catch {
            return .failure(RefusalAdvisor.advise(error, context: AdviceContext(provider: provider, report: nil)))
        }
    }

    /// Recomputes `modelAvailability` from the last list-models results and the effective
    /// catalog, and `missingDefaultModel` for the Settings default.
    func refreshAvailability() {
        var availability: [String: ModelAvailability] = [:]
        for (provider, listed) in listedModels {
            for model in catalog.imageModels(for: provider) {
                availability[model.id] = catalog.availability(of: model, listed: listed)
            }
        }
        if modelAvailability != availability { modelAvailability = availability }

        let settings = defaults
        var missing: ModelAvailability?
        if let listed = listedModels[settings.provider] {
            if let model = catalog.imageModel(provider: settings.provider, id: settings.model) {
                let state = catalog.availability(of: model, listed: listed)
                if state != .available { missing = state }
            } else if !listed.contains(settings.model) {
                let fallback = bundledCatalog.defaultImageModel(for: settings.provider)?.id
                missing = .unavailable(successor: fallback == settings.model ? nil : fallback)
            }
        }
        if missingDefaultModel != missing { missingDefaultModel = missing }
    }

    /// Image models for the Settings picker: bundled plus custom, current first (then
    /// deprecated, then retired; catalog order within each).
    public func imageModels(for provider: ProviderID) -> [CatalogModel] {
        func rank(_ status: ModelStatus) -> Int {
            switch status {
            case .current: 0
            case .deprecated: 1
            case .retired: 2
            }
        }
        return catalog.imageModels(for: provider).enumerated()
            .sorted { (rank($0.element.status), $0.offset) < (rank($1.element.status), $1.offset) }
            .map(\.element)
    }

    /// Adds a custom model ID copying `family`; false if the family is unknown or the ID exists.
    @discardableResult
    public func addCustomModel(id: String, copying family: String, provider: ProviderID) -> Bool {
        let id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, let base = bundledCatalog.imageModel(provider: provider, id: family), base.copiesFrom == nil,
              catalog.imageModel(provider: provider, id: id) == nil else { return false }
        preferences.customModels.append(CustomModelSpec(provider: provider, id: id, copiesFrom: base.id))
        return true
    }

    /// Removes a custom model; if it was the default, the default goes back to the catalog's.
    public func removeCustomModel(_ spec: CustomModelSpec) {
        guard preferences.customModels.contains(spec) else { return }
        preferences.customModels.removeAll { $0 == spec }
        if spec.provider == defaults.provider, preferences.defaultImageModelID == spec.id {
            preferences.defaultImageModelID = bundledCatalog.defaultImageModel(for: spec.provider)?.id
                ?? GenerationDefaults.fallbackModel
        }
    }
}
