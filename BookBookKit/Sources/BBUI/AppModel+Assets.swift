import BBAI
import BBAICore
import BBModel
import BBStore
import Foundation

// Phase 10 contract (main thread); bodies by the UI-core lane.

/// "Generate whole sheet" (PD §8.3): one item per unlocked sheet item, at the user's default
/// quality, with the combined estimate. Nothing is appended or enqueued yet.
public struct SheetBatchPlan: Sendable {
    public var asset: AssetID
    public var items: [QueueItem]
    /// The sheet item each queue item fills, parallel to `items`.
    public var sheetItems: [UUID]
    public var estimate: CostEstimate
    public var count: Int { items.count }

    public init(asset: AssetID, items: [QueueItem] = [], sheetItems: [UUID] = [],
                estimate: CostEstimate = CostEstimate(amount: 0)) {
        self.asset = asset
        self.items = items
        self.sheetItems = sheetItems
        self.estimate = estimate
    }
}

/// Queue labels for asset targets: the asset's name and the slot or sheet item.
enum AssetQueueDisplay {
    static func display(_ owner: SessionOwner, in content: BookContent) -> QueueItemDisplay {
        let label = BookDocument.ownerLabel(owner, in: content)
        let parts = label.components(separatedBy: " · ")
        return QueueItemDisplay(bookTitle: content.book.title, pageLabel: parts.first ?? label,
                                boxLabel: parts.dropFirst().joined(separator: " · "))
    }
}

extension AppModel {
    /// The intent a Generate press would queue, from the panel's settings and the app defaults.
    /// `prompt` is stored text (mention tokens), trimmed.
    public func generationIntent(prompt: String, quality: QualityLevel, includeStoryText: Bool, refines: VersionID?,
                                 attachedReferences: [VersionRef] = []) -> GenerationIntent {
        let settings = defaults
        return GenerationIntent(messageText: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                                refines: refines, attachedReferences: attachedReferences,
                                provider: settings.provider, model: settings.model, quality: quality,
                                includeStoryText: includeStoryText,
                                checkConsistency: preferences.consistencyCheckEnabled)
    }

    /// The estimate shown next to Generate, for any target.
    public func estimate(prompt: String, quality: QualityLevel, includeStoryText: Bool, refines: VersionID?,
                         attachedReferences: [VersionRef], target: GenerationTarget,
                         in document: BookDocument) -> CostEstimate {
        let intent = generationIntent(prompt: prompt, quality: quality, includeStoryText: includeStoryText,
                                      refines: refines, attachedReferences: attachedReferences)
        return estimate(intent, target: target, content: document.content)
    }

    /// "Regenerate with same settings" estimate for any target; nil without provenance.
    public func regenerateEstimate(_ version: Version, target: GenerationTarget, in document: BookDocument) -> CostEstimate? {
        guard let intent = (version.provenance?.intent).map(replayed) else { return nil }
        return estimate(intent, target: target, content: document.content)
    }

    /// Like `generate(prompt:…page:box:in:)` for any target (asset slots and sheet items
    /// included). `prompt` is stored text (mention tokens). Shows nothing itself; callers run
    /// the cost and real-person checks first.
    @discardableResult
    public func generate(prompt: String, quality: QualityLevel, includeStoryText: Bool, refines: VersionID?,
                         attachedReferences: [VersionRef], target: GenerationTarget,
                         in document: BookDocument) -> Bool {
        let intent = generationIntent(prompt: prompt, quality: quality, includeStoryText: includeStoryText,
                                      refines: refines, attachedReferences: attachedReferences)
        guard !intent.messageText.isEmpty else { return false }
        let (message, item) = BookMutations.makeGeneration(intent: intent, bookID: document.id, target: target,
                                                           now: now())
        return enqueue(message, prepared(item, content: document.content), in: document)
    }

    /// Unlocked sheet items with nothing pending (empty or not), planned like Draft all.
    public func sheetBatchPlan(asset: AssetID, in document: BookDocument) -> SheetBatchPlan {
        let content = document.content
        guard let sheet = content.assets[asset]?.sheet else { return SheetBatchPlan(asset: asset) }
        let settings = defaults
        var items: [QueueItem] = []
        var ids: [UUID] = []
        for sheetItem in sheet.items where !sheetItem.locked {
            guard let session = content.sessions[sheetItem.sessionID],
                  !session.messages.contains(where: { isPending($0) }) else { continue }
            let intent = GenerationIntent(messageText: SheetRequests.messageText(for: sheetItem.kind),
                                          provider: settings.provider, model: settings.model,
                                          quality: settings.quality, includeStoryText: false)
            let item = QueueItem(bookID: document.id, target: .sheetItem(asset, sheetItem.id),
                                 messageID: MessageID(), intent: intent)
            items.append(prepared(item, content: content))
            ids.append(sheetItem.id)
        }
        return SheetBatchPlan(asset: asset, items: items, sheetItems: ids,
                              estimate: CostEstimate.total(items.map(\.estimateIncludingFollowUp)))
    }

    /// Appends the pending messages and enqueues the plan. False if nothing was queued.
    /// Items locked, removed or already queued from this plan since it was made are skipped.
    @discardableResult
    public func enqueueSheetBatch(_ plan: SheetBatchPlan, in document: BookDocument) -> Bool {
        guard !plan.items.isEmpty, plan.items.count == plan.sheetItems.count else { return false }
        var queued: [QueueItem] = []
        document.performIrreversible { content in
            var dirty = DirtySet()
            for (item, id) in zip(plan.items, plan.sheetItems) {
                guard let sheetItem = content.assets[plan.asset]?.sheet?.items.first(where: { $0.id == id }),
                      !sheetItem.locked, content.session(containing: item.messageID) == nil else { continue }
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
        let items = queued
        queueOperation { await $0.enqueue(items, position: .end) }
        return true
    }

    /// The provider this request would send a real-person photo to, when the book hasn't
    /// acknowledged that provider's notice yet (A §11); nil = no notice needed.
    public func realPersonNoticeNeeded(intent: GenerationIntent, target: GenerationTarget,
                                       in document: BookDocument) -> ProviderID? {
        let content = document.content
        guard !content.book.acknowledgements.realPersonPhotoNotice.contains(intent.provider),
              let model = catalog.imageModel(provider: intent.provider, id: intent.model),
              ContextAssembler.sendsRealPersonPhoto(intent: intent, target: target, content: content, model: model)
        else { return nil }
        return intent.provider
    }

    /// The first provider among `items` (a batch's requests) that would be sent a real-person
    /// photo before the book acknowledged its notice; nil = enqueue without a notice. Shared by
    /// Generate Whole Sheet and Draft All.
    public func realPersonNoticeNeeded(for items: [QueueItem], in document: BookDocument) -> ProviderID? {
        for item in items {
            if let provider = realPersonNoticeNeeded(intent: item.intent, target: item.target, in: document) {
                return provider
            }
        }
        return nil
    }

    /// Record the acknowledgement in `Book.acknowledgements` (not undoable).
    public func acknowledgeRealPersonNotice(_ provider: ProviderID, in document: BookDocument) {
        document.performIrreversible { BookMutations.acknowledgeRealPersonNotice(provider, in: &$0) }
    }
}
