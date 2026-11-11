import BBAI
import BBAICore
import BBModel
import BBStore
import Foundation

// Phase 10 contract (main thread); bodies by the UI-core lane.

/// Queue labels for asset targets: the asset's name, then "Image".
enum AssetQueueDisplay {
    static func display(_ owner: SessionOwner, in content: BookContent) -> QueueItemDisplay {
        QueueItemDisplay(bookTitle: content.book.title, pageLabel: BookDocument.ownerLabel(owner, in: content),
                         boxLabel: "Image")
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

    /// Like `generate(prompt:…page:box:in:)` for any target (assets included). `prompt` is stored text (mention tokens). Shows nothing itself; callers run
    /// the cost and real-person checks first.
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
}
