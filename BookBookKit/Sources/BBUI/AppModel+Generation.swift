import BBAI
import BBAICore
import BBModel
import BBStore
import Foundation

// Everything that turns a Generate press, a regenerate or a fix into a queued request, in one place.

extension AppModel {
    // MARK: Generation

    /// "Regenerate with same settings": a new pending message and queue item built from the
    /// version's stored intent, unchanged (same text, same `refines`), for any target. False for
    /// versions with no provenance (imported), a target that's gone, or a real-person photo the
    /// book hasn't acknowledged sending (A §11).
    @discardableResult
    public func regenerate(_ version: Version, target: GenerationTarget, in document: BookDocument) -> Bool {
        guard let intent = (version.provenance?.intent).map(replayed) else { return false }
        let (message, item) = BookMutations.makeGeneration(intent: intent, bookID: document.id, target: target,
                                                           now: now())
        return enqueue(message, prepared(item, content: document.content), in: document)
    }

    /// A stored intent replayed now: unchanged, except the consistency follow-up follows today's
    /// Settings switch (it's captured at enqueue time, A §7.8), and `versionSource` is cleared:
    /// a replay is a plain generation, not another consistency fix (#18).
    func replayed(_ intent: GenerationIntent) -> GenerationIntent {
        var intent = intent
        intent.checkConsistency = preferences.consistencyCheckEnabled
        intent.versionSource = nil
        return intent
    }

    /// Fills in the item's estimate, display labels and enqueue time (A §7.9, §7.10), and its
    /// consistency follow-up (A §7.8): `checkConsistency` defaults to the Settings switch.
    func prepared(_ item: QueueItem, content: BookContent) -> QueueItem {
        var item = item
        if item.intent.checkConsistency == nil { item.intent.checkConsistency = preferences.consistencyCheckEnabled }
        if case .textBox = item.target { item.intent.checkConsistency = false }
        item.estimate = ownEstimate(item.intent, target: item.target, content: content)
        item.consistencyFollowUp = consistencyFollowUp(for: item.intent, target: item.target, content: content)
        item.display = AssetQueueDisplay.display(for: item.target, in: content)
        item.enqueuedAt = now()
        return item
    }

    /// What the user is shown for a generation: its own request plus its consistency follow-up
    /// when one would be queued (`intent.checkConsistency`, nil = the Settings switch; A §7.10).
    func estimate(_ intent: GenerationIntent, target: GenerationTarget, content: BookContent) -> CostEstimate {
        let own = ownEstimate(intent, target: target, content: content)
        guard let followUp = consistencyFollowUp(for: intent, target: target, content: content) else { return own }
        return CostEstimate.total([own, followUp.estimate])
    }

    /// `CostEstimator` on the effective catalog and the current price list for this request
    /// alone (the queue item's `estimate`); `.unknown` if the model or target can't be resolved
    /// or the model has no price entry.
    func ownEstimate(_ intent: GenerationIntent, target: GenerationTarget, content: BookContent) -> CostEstimate {
        guard let input = CostEstimator.estimateInput(intent: intent, target: target, content: content,
                                                      catalog: catalog) else { return .unknown }
        return CostEstimator.estimate(input, priceList: prices.current)
    }

    /// Whether a message in the session `owner` owns still has a live request (waiting, running
    /// or retrying), including one put back by Try Again (`QueueSnapshot.entry(answering:in:)`).
    func isPending(_ message: Message, in owner: SessionOwner) -> Bool {
        if let id = message.queueItemID, queueSnapshot.entry(for: id) == nil { return pendingThisLaunch.contains(id) }
        guard let entry = queueSnapshot.entry(answering: message, in: owner) else { return false }
        if case .failed = entry.state { return false }
        return true
    }

    func notePending(_ ids: some Sequence<QueueItemID>) {
        pendingThisLaunch.formUnion(ids)
    }

    /// The one path every single-request generation (`generate`, `enqueueGeneration`,
    /// `regenerate`, region edits) enqueues through. Refuses (false, nothing appended) when the
    /// request would send a real-person photo to a provider the book hasn't acknowledged (A §11):
    /// callers show the notice first, but the book can change while the cost alert is up.
    func enqueue(_ message: Message, _ item: QueueItem, in document: BookDocument) -> Bool {
        guard realPersonNoticeNeeded(intent: item.intent, target: item.target, in: document) == nil,
              document.performIrreversible({
            BookMutations.appendPendingMessage(message, target: item.target, to: &$0)
        }) else { return false }
        pendingThisLaunch.insert(item.id)
        // Chained (after the restore) so presses reach the queue in order.
        queueOperation { await $0.enqueue([item], position: .end) }
        return true
    }

    /// `owner` owns the session the message is in.
    public func status(of message: Message, in owner: SessionOwner) -> MessageStatus {
        MessageStatus.resolve(message, in: owner, snapshot: queueSnapshot, pendingThisLaunch: pendingThisLaunch,
                              deliveryFailures: deliveryFailures) { typicalDuration(for: $0) }
    }

    /// The model's typical seconds for a queue item: the image model at its quality, or the
    /// vision model for a consistency check. Nil when the catalog doesn't say.
    func typicalDuration(for item: QueueItem) -> Double? {
        let intent = item.intent
        return item.kind == .image
            ? catalog.imageModel(provider: intent.provider, id: intent.model)?.typicalDurationSeconds[intent.quality]
            : catalog.textModel(provider: intent.provider, id: intent.model)?.typicalDurationSeconds
    }

    /// e.g. "GPT Image 2.5 Sunburst".
    public var defaultModelName: String {
        catalog.imageModel(provider: defaults.provider, id: defaults.model)?.displayName ?? defaults.model
    }

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

    /// The estimate shown next to Generate, for any target. Sync: built from the document's
    /// current content.
    public func estimate(prompt: String, quality: QualityLevel, includeStoryText: Bool, refines: VersionID?,
                         attachedReferences: [VersionRef], target: GenerationTarget,
                         in document: BookDocument) -> CostEstimate {
        let intent = generationIntent(prompt: prompt, quality: quality, includeStoryText: includeStoryText,
                                      refines: refines, attachedReferences: attachedReferences)
        return estimate(intent, target: target, content: document.content)
    }

    /// The estimate for "Regenerate with same settings" (the version's stored intent, replayed),
    /// for any target; nil for a version with no provenance.
    public func regenerateEstimate(_ version: Version, target: GenerationTarget, in document: BookDocument) -> CostEstimate? {
        guard let intent = (version.provenance?.intent).map(replayed) else { return nil }
        return estimate(intent, target: target, content: document.content)
    }

    /// Appends the pending user message (non-undoable) and enqueues the request, for any target
    /// (assets included). `prompt` is stored text (mention tokens); `refines` is the selected
    /// version (nil = a new image). False if the prompt is empty, the target is gone, the book
    /// is read-only, or the real-person notice is still needed (A §11). Shows nothing itself;
    /// callers run the cost and real-person checks first.
    @discardableResult
    public func generate(prompt: String, quality: QualityLevel, includeStoryText: Bool, refines: VersionID?,
                         attachedReferences: [VersionRef], target: GenerationTarget,
                         in document: BookDocument) -> Bool {
        enqueueGeneration(generationIntent(prompt: prompt, quality: quality, includeStoryText: includeStoryText,
                                           refines: refines, attachedReferences: attachedReferences),
                          target: target, in: document)
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
    /// photo before the book acknowledged its notice; nil = enqueue without a notice. Used by
    /// Draft All.
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

    /// The estimate for a prepared intent (e.g. `consistencyFixIntent`), including its
    /// consistency follow-up when `intent.checkConsistency` is true.
    public func estimate(for intent: GenerationIntent, target: GenerationTarget, in document: BookDocument) -> CostEstimate {
        estimate(intent, target: target, content: document.content)
    }

    /// Appends the pending message and enqueues a prepared intent unchanged (its
    /// `versionSource` and `checkConsistency` included), like `generate`. Callers run the cost
    /// and real-person checks first. False if the message is empty, the target is gone, the
    /// book is read-only, or it would send a real-person photo whose notice the book hasn't
    /// acknowledged (`realPersonNoticeNeeded(intent:target:in:)`, A §11).
    @discardableResult
    public func enqueueGeneration(_ intent: GenerationIntent, target: GenerationTarget,
                                  in document: BookDocument) -> Bool {
        guard !intent.messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let (message, item) = BookMutations.makeGeneration(intent: intent, bookID: document.id, target: target,
                                                           now: now())
        return enqueue(message, prepared(item, content: document.content), in: document)
    }
}
