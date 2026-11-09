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
        let intent = GenerationIntent(messageText: prompt, refines: refines, provider: defaults.provider,
                                      model: defaults.model, quality: defaults.quality,
                                      includeStoryText: defaults.includeStoryText)
        return makeGeneration(intent: intent, bookID: bookID, page: page, box: box, now: now)
    }

    /// Builds the pending user message and queue item for a stored intent unchanged
    /// ("Regenerate with same settings": same text, same `refines`, same references).
    public static func makeGeneration(intent: GenerationIntent, bookID: BookID, page: PageID, box: BoxID,
                                      now: Date) -> (message: Message, item: QueueItem) {
        let itemID = QueueItemID()
        let message = Message(role: .user, text: intent.messageText, refines: intent.refines,
                              attachedReferences: intent.attachedReferences, queueItemID: itemID, createdAt: now)
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
    ///
    /// Phase 12: the version gets `versionID` (default: the queue's `delivery.versionID`) and the
    /// intent's `versionSource` when set. A consistency check's delivery goes to
    /// `applyConsistencyDelivery` instead.
    public static func applyDelivery(_ delivery: GenerationDelivery, storedImage: ImageRef?,
                                     to content: inout BookContent, versionID: VersionID? = nil,
                                     now: Date) -> DirtySet {
        guard delivery.item.kind == .image else { return applyConsistencyDelivery(delivery, to: &content) }
        let versionID = versionID ?? delivery.versionID
        // Idempotent (Phase 16b): a redelivery of a picture already in the book changes nothing.
        if case .success = delivery.outcome, content.sessions.values.contains(where: { $0.version(versionID) != nil }) {
            return DirtySet()
        }
        guard case let .pageBox(pageID, boxID) = delivery.item.target else {
            return applyAssetDelivery(delivery, storedImage: storedImage, to: &content, versionID: versionID, now: now)
        }
        let page = content.pages[pageID]
        let slot = page?.images[boxID]
        let owner = SessionOwner.pageBox(pageID, boxID)
        // By message first: box IDs can move, the message can't (Phase 5 follow-up).
        guard let sessionID = content.session(containing: delivery.item.messageID)?.id
                ?? slot?.sessionID ?? content.sessions.first(where: { $0.value.owner == owner })?.key,
              var session = content.sessions[sessionID] else { return DirtySet() }

        var dirty = DirtySet()
        let (changed, delivered) = record(delivery, storedImage: storedImage, versionID: versionID, now: now,
                                          in: &session, content: content)
        if changed { dirty.sessions.insert(session.id) }

        if let version = delivered {
            // The box may have moved since the request: place into whichever box holds the session.
            var home: (PageID, BoxID)? = slot?.sessionID == session.id ? (pageID, boxID) : nil
            if home == nil {
                outer: for (id, page) in content.pages {
                    for (box, candidate) in page.images where candidate.sessionID == session.id {
                        home = (id, box)
                        break outer
                    }
                }
            }
            if let home, placeIfEmpty(version.id, session: session.id, page: home.0, box: home.1, in: &content) {
                dirty.pages.insert(home.0)
            }
        }

        content.sessions[session.id] = session
        return dirty
    }

    /// The source a delivered version records: the intent's `versionSource` (e.g.
    /// `.consistencyFix`), else `.regionEdit` with a mask, else `.generated`.
    public static func versionSource(for intent: GenerationIntent) -> VersionSource {
        intent.versionSource ?? (intent.regionMask == nil ? .generated : .regionEdit)
    }

    /// The shared part of a delivery into `session`: clears the message's `queueItemID` and, for
    /// a success with a stored image, appends the version (and sets the message's
    /// `producedVersion`). Returns whether the session changed and the version added.
    static func record(_ delivery: GenerationDelivery, storedImage: ImageRef?, versionID: VersionID, now: Date,
                       in session: inout Session, content: BookContent) -> (changed: Bool, version: Version?) {
        var changed = false
        let messageIndex = session.messages.firstIndex { $0.id == delivery.item.messageID }
        if let messageIndex, session.messages[messageIndex].queueItemID != nil {
            session.messages[messageIndex].queueItemID = nil
            changed = true
        }
        guard case let .success(result, provenance) = delivery.outcome, let storedImage else { return (changed, nil) }
        let resolved = resolvingDeletedMentions(provenance, message: messageIndex.map { session.messages[$0] },
                                                in: content)
        let version = Version(id: versionID, image: storedImage, pixelSize: result.pixelSize,
                              source: versionSource(for: resolved.intent),
                              parent: resolved.intent.refines, createdAt: now, provenance: resolved)
        session.versions.append(version)
        if let messageIndex { session.messages[messageIndex].producedVersion = version.id }
        return (true, version)
    }

    // MARK: Phase 12 consistency checks (A §7.8; not undoable)

    /// A consistency check's delivery: on `.consistency(report)`, the checked version's report is
    /// replaced; nothing else changes. A failure (or cancel) changes nothing at all, and a
    /// version that's gone is ignored. Returns the session changed, if any.
    public static func applyConsistencyDelivery(_ delivery: GenerationDelivery,
                                                to content: inout BookContent) -> DirtySet {
        guard case let .consistency(report) = delivery.outcome, let versionID = delivery.item.kind.checkedVersion,
              let session = content.sessions.values.first(where: { $0.version(versionID) != nil }),
              let index = session.versions.firstIndex(where: { $0.id == versionID }) else { return DirtySet() }
        content.sessions[session.id]?.versions[index].consistency = report
        return DirtySet(sessions: [session.id])
    }

    /// Dismisses (or restores) a version's consistency warning (PD §8.9). Empty if the version
    /// has no report or nothing changed.
    public static func setConsistencyDismissed(_ dismissed: Bool, version: VersionID, in sessionID: SessionID,
                                               to content: inout BookContent) -> DirtySet {
        guard let index = content.sessions[sessionID]?.versions.firstIndex(where: { $0.id == version }),
              let report = content.sessions[sessionID]?.versions[index].consistency,
              report.dismissed != dismissed else { return DirtySet() }
        content.sessions[sessionID]?.versions[index].consistency?.dismissed = dismissed
        return DirtySet(sessions: [sessionID])
    }

    /// Places `version` (zoom 1, centred) if the box exists, belongs to `session` and is empty.
    private static func placeIfEmpty(_ version: VersionID, session: SessionID, page pageID: PageID, box boxID: BoxID,
                                     in content: inout BookContent) -> Bool {
        guard let page = content.pages[pageID], let slot = page.images[boxID], slot.sessionID == session,
              slot.placement == nil, let template = content.template(for: page), let box = template.box(boxID)
        else { return false }
        let placement = ImagePlacement(versionID: version, boxAspectWhenPlaced: content.boxAspect(box, in: template))
        content.pages[pageID]?.images[boxID]?.placement = placement
        content.pages[pageID]?.images[boxID]?.acknowledged.boxAspect = nil
        return true
    }

    // MARK: Phase 8 session mutations (not undoable)

    /// Stars or unstars a version.
    public static func setStarred(_ starred: Bool, version: VersionID, in sessionID: SessionID,
                                  to content: inout BookContent) -> DirtySet {
        guard var session = content.sessions[sessionID],
              let index = session.versions.firstIndex(where: { $0.id == version }),
              session.versions[index].starred != starred else { return DirtySet() }
        session.versions[index].starred = starred
        content.sessions[sessionID] = session
        return DirtySet(sessions: [sessionID])
    }

    /// Removes a version and empties every box (on any page) that had it placed. Messages that
    /// produced it forget it; later versions keep their `parent` (lineage stops at the gap).
    public static func deleteVersion(_ version: VersionID, in sessionID: SessionID,
                                     to content: inout BookContent) -> DirtySet {
        guard var session = content.sessions[sessionID], session.version(version) != nil else { return DirtySet() }
        let grandparent = session.version(version)?.parent
        session.versions.removeAll { $0.id == version }
        // Children of the deleted version take its parent, so their lineage has no gap.
        for index in session.versions.indices where session.versions[index].parent == version {
            session.versions[index].parent = grandparent
        }
        for index in session.messages.indices where session.messages[index].producedVersion == version {
            session.messages[index].producedVersion = nil
        }
        content.sessions[sessionID] = session
        var dirty = DirtySet(sessions: [sessionID])
        dirty.pages = clearPlacements(of: [version], in: &content)
        dirty.assets = clearAssetChoices(of: [version], in: &content)
        return dirty
    }

    /// Hides the thread (bumps `resetEpoch`). With `keepVersions: false` the versions go too, and
    /// the boxes showing them are emptied.
    public static func resetSession(_ sessionID: SessionID, keepVersions: Bool,
                                    to content: inout BookContent) -> DirtySet {
        guard var session = content.sessions[sessionID] else { return DirtySet() }
        session.resetEpoch += 1
        var dirty = DirtySet(sessions: [sessionID])
        if !keepVersions {
            let removed = Set(session.versions.map(\.id))
            session.versions = []
            dirty.pages = clearPlacements(of: removed, in: &content)
            dirty.assets = clearAssetChoices(of: removed, in: &content)
        }
        content.sessions[sessionID] = session
        return dirty
    }

    /// Adds an imported picture (no provenance) to the box's session; places it only if the box
    /// is empty, like a delivery. Empty result if the box or session is gone.
    public static func appendImportedVersion(image: ImageRef, pixelSize: PixelSize, page: PageID, box: BoxID,
                                             to content: inout BookContent, versionID: VersionID = VersionID(),
                                             now: Date) -> DirtySet {
        guard let slot = content.pages[page]?.images[box], var session = content.sessions[slot.sessionID]
        else { return DirtySet() }
        session.versions.append(Version(id: versionID, image: image, pixelSize: pixelSize, source: .imported,
                                        createdAt: now))
        content.sessions[session.id] = session
        var dirty = DirtySet(sessions: [session.id])
        if placeIfEmpty(versionID, session: session.id, page: page, box: box, in: &content) {
            dirty.pages.insert(page)
        }
        return dirty
    }

    private static func clearPlacements(of versions: Set<VersionID>, in content: inout BookContent) -> Set<PageID> {
        var changed: Set<PageID> = []
        for (pageID, page) in content.pages {
            for (boxID, slot) in page.images {
                guard let placement = slot.placement, versions.contains(placement.versionID) else { continue }
                content.pages[pageID]?.images[boxID]?.placement = nil
                changed.insert(pageID)
            }
        }
        return changed
    }
}
