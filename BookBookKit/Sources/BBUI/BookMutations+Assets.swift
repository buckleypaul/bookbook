import BBAI
import BBModel
import BBStore
import Foundation

/// Phase 10 non-undoable mutations for asset sessions, generations for any target, asset
/// deletion and the real-person acknowledgement (A §4.3, §6.3, §11). Pure on `BookContent`,
/// so open books (through `performIrreversible`) and closed books share them.
extension BookMutations {
    /// The session an owner writes into: the page box's slot or the asset's `sessionID`. Nil
    /// if the box or asset is gone (the session itself may not exist yet for a legacy asset).
    public static func sessionID(for owner: SessionOwner, in content: BookContent) -> SessionID? {
        switch owner {
        case let .pageBox(page, box):
            return content.pages[page]?.images[box]?.sessionID
        case let .asset(asset):
            return content.assets[asset]?.sessionID
        case let .textBox(page, box):
            return content.pages[page]?.textStyles[box]?.sessionID
        }
    }

    /// The pending user message and queue item for an intent on any target.
    public static func makeGeneration(intent: GenerationIntent, bookID: BookID, target: GenerationTarget,
                                      now: Date) -> (message: Message, item: QueueItem) {
        let itemID = QueueItemID()
        let message = Message(role: .user, text: intent.messageText, refines: intent.refines,
                              attachedReferences: intent.attachedReferences, queueItemID: itemID, createdAt: now)
        let item = QueueItem(id: itemID, bookID: bookID, target: target, messageID: message.id, intent: intent)
        return (message, item)
    }

    /// Appends a pending user message to the target's session (current epoch). An asset whose
    /// session is missing (legacy file) gets an empty one first. Empty if gone.
    public static func appendPendingMessage(_ message: Message, target: GenerationTarget,
                                            to content: inout BookContent) -> DirtySet {
        guard let id = sessionID(for: target.owner, in: content) else { return DirtySet() }
        if content.sessions[id] == nil, target.owner.assetID != nil {
            content.sessions[id] = Session(id: id, owner: target.owner)
        }
        guard var session = content.sessions[id] else { return DirtySet() }
        var message = message
        message.epoch = session.resetEpoch
        session.messages.append(message)
        content.sessions[id] = session
        return DirtySet(sessions: [id])
    }

    /// A finished generation for an asset: the version goes into the session (found by
    /// message first) and becomes the asset's `chosen` (the newest image always wins, bumping
    /// the revision; earlier versions stay in the session).
    static func applyAssetDelivery(_ delivery: GenerationDelivery, storedImage: ImageRef?,
                                   to content: inout BookContent, versionID: VersionID, now: Date) -> DirtySet {
        let owner = delivery.item.target.owner
        guard let sessionID = content.session(containing: delivery.item.messageID)?.id
                ?? Self.sessionID(for: owner, in: content),
              var session = content.sessions[sessionID] else { return DirtySet() }
        var dirty = DirtySet()
        let (changed, delivered) = record(delivery, storedImage: storedImage, versionID: versionID, now: now,
                                          in: &session, content: content)
        if changed { dirty.sessions.insert(sessionID) }
        if let version = delivered {
            content.sessions[sessionID] = session
            if let asset = chooseLatest(version.id, session: sessionID, in: &content) { dirty.assets.insert(asset) }
            return dirty
        }
        content.sessions[sessionID] = session
        return dirty
    }

    /// A request queued before its asset was deleted still holds the token in the stored intent.
    /// The answered message's text was rewritten to plain names at delete, so the delivered
    /// provenance takes it (Version details and Regenerate keep the name).
    static func resolvingDeletedMentions(_ provenance: Provenance, message: Message?,
                                         in content: BookContent) -> Provenance {
        guard let message, MentionText.mentionedAssets(in: provenance.intent.messageText)
            .contains(where: { content.assets[$0] == nil }) else { return provenance }
        var out = provenance
        out.intent.messageText = message.text
        return out
    }

    /// Adds an imported picture to an asset's session, with the real-person answer, and
    /// makes it the asset's image. Creates the session if it's missing (legacy asset). Empty if
    /// the asset is gone.
    public static func appendImportedAssetVersion(image: ImageRef, pixelSize: PixelSize, owner: SessionOwner,
                                                  depictsRealPerson: Bool, to content: inout BookContent,
                                                  versionID: VersionID = VersionID(), now: Date) -> DirtySet {
        guard owner.assetID != nil, let id = sessionID(for: owner, in: content) else { return DirtySet() }
        if content.sessions[id] == nil { content.sessions[id] = Session(id: id, owner: owner) }
        content.sessions[id]?.versions.append(Version(id: versionID, image: image, pixelSize: pixelSize,
                                                      source: .imported, createdAt: now,
                                                      depictsRealPerson: depictsRealPerson))
        var dirty = DirtySet(sessions: [id])
        if let asset = chooseLatest(versionID, session: id, in: &content) { dirty.assets.insert(asset) }
        return dirty
    }

    /// Makes `version` the asset's `chosen` when `session` is its session (the asset's image is
    /// always its newest version). Returns the asset changed, nil when nothing changed. The
    /// revision follows `Asset.revised(from:)`.
    static func chooseLatest(_ version: VersionID, session: SessionID, in content: inout BookContent) -> AssetID? {
        guard let assetID = content.sessions[session]?.owner.assetID, let old = content.assets[assetID],
              old.sessionID == session, old.chosen != version else { return nil }
        var asset = old
        asset.chosen = version
        content.assets[assetID] = asset.revised(from: old)
        return assetID
    }

    /// Clears every asset's `chosen` that points at one of `versions` (deleted).
    static func clearAssetChoices(of versions: Set<VersionID>, in content: inout BookContent) -> Set<AssetID> {
        guard !versions.isEmpty else { return [] }
        var changed: Set<AssetID> = []
        for (id, old) in content.assets {
            guard let chosen = old.chosen, versions.contains(chosen) else { continue }
            var asset = old
            asset.chosen = nil
            content.assets[id] = asset.revised(from: old)
            changed.insert(id)
        }
        return changed
    }

    /// Deletes an asset (PD §8.3, §8.10): off every checklist, its mention tokens in every
    /// session's messages and version intents become its name as plain text, `assets/<id>.json` goes. Images and
    /// sessions stay. Empty if unknown.
    public static func deleteAsset(_ id: AssetID, from content: inout BookContent) -> DirtySet {
        guard let asset = content.assets[id] else { return DirtySet() }
        var dirty = DirtySet(deletedAssets: [id])
        content.assets[id] = nil
        for (pageID, page) in content.pages where page.assetChecklist.contains(id) {
            content.pages[pageID]?.assetChecklist.removeAll { $0 == id }
            dirty.pages.insert(pageID)
        }
        for (sessionID, old) in content.sessions {
            var session = old
            for i in session.messages.indices {
                session.messages[i].text = MentionText.replacingMentions(of: id, with: asset.name,
                                                                         in: session.messages[i].text)
            }
            // Regenerate with Same Settings and Version details keep the name too.
            for i in session.versions.indices {
                guard let text = session.versions[i].provenance?.intent.messageText else { continue }
                session.versions[i].provenance?.intent.messageText = MentionText.replacingMentions(
                    of: id, with: asset.name, in: text)
            }
            guard session != old else { continue }
            content.sessions[sessionID] = session
            dirty.sessions.insert(sessionID)
        }
        return dirty
    }

    /// Records that the book acknowledged `provider`'s real-person photo notice.
    public static func acknowledgeRealPersonNotice(_ provider: ProviderID, in content: inout BookContent) -> DirtySet {
        guard !content.book.acknowledgements.realPersonPhotoNotice.contains(provider) else { return DirtySet() }
        content.book.acknowledgements.realPersonPhotoNotice.append(provider)
        return DirtySet(book: true)
    }
}
