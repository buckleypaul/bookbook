import BBAI
import BBAICore
import BBModel
import BBStore
import Foundation

/// The settings a Generate press uses in the slice (Phase 9 adds the per-book and app settings).
public struct GenerationDefaults: Hashable, Sendable {
    public var provider: ProviderID
    public var model: String
    public var quality: QualityLevel
    public var includeStoryText: Bool

    public init(provider: ProviderID = .openai, model: String = GenerationDefaults.fallbackModel,
                quality: QualityLevel = .standard, includeStoryText: Bool = true) {
        self.provider = provider
        self.model = model
        self.quality = quality
        self.includeStoryText = includeStoryText
    }

    /// Used when the catalog can't name a default (it should: `gpt-image-2.5-sunburst`).
    public static let fallbackModel = "gpt-image-2.5-sunburst"
}

/// Pure, non-undoable session mutations used through `BookDocument.performIrreversible` (open
/// books) or directly on a loaded `BookContent` (closed books). A §6.3, §6.4, §7.9.
public enum BookMutations {
    /// Builds the pending user message and its queue item for a Generate press.
    public static func makeGeneration(prompt: String, refines: VersionID?, defaults: GenerationDefaults,
                                      bookID: BookID, page: PageID, box: BoxID,
                                      now: Date) -> (message: Message, item: QueueItem) {
        let itemID = QueueItemID()
        let message = Message(role: .user, text: prompt, refines: refines, queueItemID: itemID, createdAt: now)
        let intent = GenerationIntent(messageText: prompt, refines: refines, provider: defaults.provider,
                                      model: defaults.model, quality: defaults.quality,
                                      includeStoryText: defaults.includeStoryText)
        let item = QueueItem(id: itemID, bookID: bookID, target: .pageBox(page, box), messageID: message.id,
                             intent: intent)
        return (message, item)
    }

    /// Appends a pending user message to the box's session (in the session's current epoch).
    /// Returns an empty set if the page, box or session is gone.
    public static func appendPendingMessage(_ message: Message, page: PageID, box: BoxID,
                                            to content: inout BookContent) -> DirtySet {
        guard let slot = content.pages[page]?.images[box], var session = content.sessions[slot.sessionID] else {
            return DirtySet()
        }
        var message = message
        message.epoch = session.resetEpoch
        session.messages.append(message)
        content.sessions[slot.sessionID] = session
        return DirtySet(sessions: [slot.sessionID])
    }

    /// Writes a finished generation into the book (A §6.4).
    ///
    /// - Success (with `storedImage`, the ref `BookStore.storeImage` returned): adds a
    ///   `.generated` version with the provenance, sets the message's `producedVersion`, clears
    ///   its `queueItemID`, and places the version (zoom 1, centred) only if the box is empty.
    /// - Failure, or success without a stored image: clears the message's `queueItemID` only.
    ///
    /// The session is found through the target even if its page is gone: page commands never
    /// delete sessions, so a page deleted while the request ran (and later restored by undo)
    /// keeps the result in its strip. Placement needs the page and slot to exist.
    ///
    /// Returns what changed; empty if the session is gone.
    public static func applyDelivery(_ delivery: GenerationDelivery, storedImage: ImageRef?,
                                     to content: inout BookContent, versionID: VersionID = VersionID(),
                                     now: Date) -> DirtySet {
        guard case let .pageBox(pageID, boxID) = delivery.item.target else { return DirtySet() }
        let page = content.pages[pageID]
        let slot = page?.images[boxID]
        let owner = SessionOwner.pageBox(pageID, boxID)
        guard let sessionID = slot?.sessionID ?? content.sessions.first(where: { $0.value.owner == owner })?.key,
              var session = content.sessions[sessionID] else { return DirtySet() }

        var dirty = DirtySet()
        let messageIndex = session.messages.firstIndex { $0.id == delivery.item.messageID }
        if let messageIndex, session.messages[messageIndex].queueItemID != nil {
            session.messages[messageIndex].queueItemID = nil
            dirty.sessions.insert(session.id)
        }

        if case let .success(result, provenance) = delivery.outcome, let storedImage {
            let version = Version(id: versionID, image: storedImage, pixelSize: result.pixelSize, source: .generated,
                                  parent: provenance.intent.refines, createdAt: now, provenance: provenance)
            session.versions.append(version)
            if let messageIndex { session.messages[messageIndex].producedVersion = version.id }
            dirty.sessions.insert(session.id)

            if let page, let slot, slot.placement == nil, let template = content.template(for: page),
               let box = template.box(boxID) {
                let placement = ImagePlacement(versionID: version.id, boxAspectWhenPlaced: content.boxAspect(box))
                content.pages[pageID]?.images[boxID]?.placement = placement
                dirty.pages.insert(pageID)
            }
        }

        content.sessions[session.id] = session
        return dirty
    }
}
