import BBAI
import BBAICore
import BBModel
import Foundation

// Phase 12 (A §7.8, PD §8.9): the consistency check as the views use it.
//
// - Automatic follow-ups need nothing from the views: when the Settings switch is on, every
//   generation queued through `AppModel` captures `checkConsistency` and its follow-up, and the
//   estimates shown (single requests, Draft All) include the follow-up.
// - The version's latest result is `Version.consistency` (`showsWarning` for the badge).
// - On-demand checks, the one-click fix and dismissing a warning go through the API below.

extension AppModel {
    // MARK: Model

    /// The vision model checks use: the Settings default (`defaultConsistencyModelID`) when the
    /// catalog has it and it isn't retired, else the catalog's first current vision model. nil =
    /// none in the catalog (no follow-ups are queued and estimates leave them out).
    public var consistencyModel: CatalogTextModel? {
        let vision = catalog.textModels(kind: .vision)
        if let chosen = vision.first(where: { $0.id == preferences.defaultConsistencyModelID }), chosen.status != .retired {
            return chosen
        }
        return vision.first { $0.status == .current } ?? vision.first { $0.status != .retired }
    }

    /// Whether a check can run: there's a vision model and its provider is wired.
    public var canCheckConsistency: Bool {
        consistencyModel.map { visionProviderIDs.contains($0.provider) } ?? false
    }

    /// The follow-up a generation with `intent` would queue (`intent.checkConsistency`, nil = the
    /// Settings switch), with its estimate from the images the check would send. nil when checks
    /// can't run (`canCheckConsistency`): then nothing is queued and estimates leave it out.
    func consistencyFollowUp(for intent: GenerationIntent, target: GenerationTarget,
                             content: BookContent) -> ConsistencyFollowUp? {
        // Text-box decorations (A §7.13) are never checked: there are no assets to compare.
        if case .textBox = target { return nil }
        guard intent.checkConsistency ?? preferences.consistencyCheckEnabled, canCheckConsistency,
              let model = consistencyModel else { return nil }
        let count = ConsistencyAssembler.imageCount(intent: intent, target: target, content: content,
                                                    provider: model.provider)
            ?? ConsistencyAssembler.conservativeImageCount
        return ConsistencyFollowUp(provider: model.provider, model: model.id,
                                   estimate: consistencyEstimator(model, count, prices.current))
    }

    // MARK: On-demand check

    /// The estimate for checking one version on demand (any version, imported included).
    /// `.unknown` when there's no vision model; a book that isn't open, or a version that can't
    /// be resolved, is estimated with a conservative image count.
    public func consistencyCheckEstimate(bookID: BookID, sessionID: SessionID, versionID: VersionID) -> CostEstimate {
        guard let model = consistencyModel else { return .unknown }
        let count = openBooks.document(for: bookID).flatMap {
            ConsistencyAssembler.plan(version: versionID, content: $0.content, provider: model.provider)?.imageCount
        } ?? ConsistencyAssembler.conservativeImageCount
        return consistencyEstimator(model, count, prices.current)
    }

    /// The provider whose real-person notice must be acknowledged before checking this version
    /// (it is a real-person photo and the book hasn't acknowledged the vision provider's notice,
    /// A §11); nil = no notice needed.
    public func realPersonNoticeNeededForCheck(bookID: BookID, versionID: VersionID) -> ProviderID? {
        guard let model = consistencyModel, let document = openBooks.document(for: bookID),
              ConsistencyAssembler.sendsRealPersonPhoto(versionID: versionID, content: document.content,
                                                        provider: model.provider) else { return nil }
        return model.provider
    }

    /// Queues a check of one version at the front of the queue (it runs after the current
    /// item). Its result replaces the version's `consistency`. Not a version, not undoable.
    /// Callers show `consistencyCheckEstimate` first if they confirm costs. False if the book
    /// isn't open or is read-only, the version is gone, checks can't run (`canCheckConsistency`),
    /// or a check of this version is already pending.
    @discardableResult
    public func checkConsistency(bookID: BookID, sessionID: SessionID, versionID: VersionID) -> Bool {
        guard canCheckConsistency, let document = openBooks.document(for: bookID), document.isEditable,
              let model = consistencyModel,
              !isConsistencyCheckPending(versionID: versionID),
              realPersonNoticeNeededForCheck(bookID: bookID, versionID: versionID) == nil else { return false }
        let content = document.content
        guard let session = content.sessions[sessionID], let version = session.version(versionID),
              let target = ConsistencyAssembler.target(for: session, in: content) else { return false }
        let intent = GenerationIntent(messageText: "", refines: versionID, provider: model.provider, model: model.id,
                                      quality: version.provenance?.intent.quality ?? .draft,
                                      includeStoryText: version.provenance?.intent.includeStoryText ?? true)
        var display: QueueItemDisplay
        switch target {
        case let .pageBox(page, box): display = DraftAllPlanner.display(page: page, box: box, in: content)
        case .asset: display = AssetQueueDisplay.display(target.owner, in: content)
        case let .textBox(page, box): display = DraftAllPlanner.textStyleDisplay(page: page, box: box, in: content)
        }
        display.boxLabel = ConsistencyQueueLabel.label(for: display.boxLabel)
        let item = QueueItem(bookID: bookID, target: target,
                             messageID: session.messages.first { $0.producedVersion == versionID }?.id ?? MessageID(),
                             intent: intent,
                             estimate: consistencyCheckEstimate(bookID: bookID, sessionID: sessionID, versionID: versionID),
                             display: display, enqueuedAt: now(), kind: .consistencyCheck(versionID))
        queueOperation { await $0.enqueue([item], position: .front) }
        return true
    }

    /// The latest queue entry checking this version (waiting, running, retrying or failed), if
    /// any. A failed entry carries the advice (`advice(for:)`); Retry and Remove work as usual.
    public func consistencyCheckEntry(versionID: VersionID) -> QueueEntry? {
        queueSnapshot.entries.last { $0.item.kind.checkedVersion == versionID }
    }

    /// True while a check of this version is waiting, running or retrying (show "Checking…").
    public func isConsistencyCheckPending(versionID: VersionID) -> Bool {
        guard let entry = consistencyCheckEntry(versionID: versionID) else { return false }
        if case .failed = entry.state { return false }
        return true
    }

    // MARK: One-click fix and dismiss

    /// The one-click fix (A §7.8): a refinement of the version whose message is the correction
    /// built from its differences, with `versionSource: .consistencyFix`, the default image model,
    /// the version's quality and story-text setting, and `checkConsistency` per the switch. Run
    /// it through the usual confirm-cost-then-enqueue path: `estimate(for:target:in:)`, then
    /// `enqueueGeneration(_:target:in:)`. nil if the book isn't open, or the version has no
    /// report or no differences.
    public func consistencyFixIntent(bookID: BookID, sessionID: SessionID, versionID: VersionID) -> GenerationIntent? {
        guard let content = openBooks.document(for: bookID)?.content,
              let version = content.sessions[sessionID]?.version(versionID),
              let report = version.consistency, !report.differences.isEmpty else { return nil }
        let settings = defaults
        let base = version.provenance?.intent
        return GenerationIntent(messageText: correctionMessage(report.differences), refines: versionID,
                                provider: settings.provider, model: settings.model,
                                quality: base?.quality ?? settings.quality,
                                includeStoryText: base?.includeStoryText ?? true,
                                checkConsistency: preferences.consistencyCheckEnabled, versionSource: .consistencyFix)
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

    /// Hides (or shows again) a version's consistency warning (PD §8.9). Not undoable, like
    /// starring. False if nothing changed.
    @discardableResult
    public func setConsistencyWarningDismissed(_ dismissed: Bool, sessionID: SessionID, versionID: VersionID,
                                               in document: BookDocument) -> Bool {
        document.performIrreversible {
            BookMutations.setConsistencyDismissed(dismissed, version: versionID, in: sessionID, to: &$0)
        }
    }
}
