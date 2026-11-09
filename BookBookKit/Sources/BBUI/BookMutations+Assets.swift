import BBAI
import BBModel
import BBStore
import Foundation

/// Phase 10 non-undoable mutations for asset sessions, generations for any target, asset
/// deletion and the real-person acknowledgement (A §4.3, §6.3, §11). Pure on `BookContent`,
/// so open books (through `performIrreversible`) and closed books share them.
extension BookMutations {
    /// The session an owner writes into: the page box's slot, the asset slot's or the sheet
    /// item's `sessionID`. Nil if it's gone.
    public static func sessionID(for owner: SessionOwner, in content: BookContent) -> SessionID? {
        switch owner {
        case let .pageBox(page, box):
            return content.pages[page]?.images[box]?.sessionID
        case let .assetReference(asset, slot):
            return content.assets[asset]?.references.first { $0.id == slot }?.sessionID
        case let .sheetItem(asset, item):
            return content.assets[asset]?.sheet?.items.first { $0.id == item }?.sessionID
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

    /// Appends a pending user message to the target's session (current epoch). Empty if gone.
    public static func appendPendingMessage(_ message: Message, target: GenerationTarget,
                                            to content: inout BookContent) -> DirtySet {
        guard let id = sessionID(for: target.owner, in: content), var session = content.sessions[id] else {
            return DirtySet()
        }
        var message = message
        message.epoch = session.resetEpoch
        session.messages.append(message)
        content.sessions[id] = session
        return DirtySet(sessions: [id])
    }

    /// A finished generation for an asset slot or sheet item: the version goes into the
    /// session (found by message first), and becomes the slot's or item's `chosen` if nothing
    /// is chosen yet (bumping the revision when that's the primary slot).
    static func applyAssetDelivery(_ delivery: GenerationDelivery, storedImage: ImageRef?,
                                   to content: inout BookContent, versionID: VersionID, now: Date) -> DirtySet {
        let owner = delivery.item.target.owner
        guard let sessionID = content.session(containing: delivery.item.messageID)?.id
                ?? Self.sessionID(for: owner, in: content),
              var session = content.sessions[sessionID] else { return DirtySet() }
        var dirty = DirtySet()
        let messageIndex = session.messages.firstIndex { $0.id == delivery.item.messageID }
        if let messageIndex, session.messages[messageIndex].queueItemID != nil {
            session.messages[messageIndex].queueItemID = nil
            dirty.sessions.insert(sessionID)
        }
        if case let .success(result, provenance) = delivery.outcome, let storedImage {
            let provenance = resolvingDeletedMentions(provenance, message: messageIndex.map { session.messages[$0] },
                                                      in: content)
            let version = Version(id: versionID, image: storedImage, pixelSize: result.pixelSize,
                                  source: provenance.intent.regionMask == nil ? .generated : .regionEdit,
                                  parent: provenance.intent.refines, createdAt: now, provenance: provenance)
            session.versions.append(version)
            if let messageIndex { session.messages[messageIndex].producedVersion = version.id }
            dirty.sessions.insert(sessionID)
            content.sessions[sessionID] = session
            if let asset = chooseIfUnset(version.id, session: sessionID, in: &content) { dirty.assets.insert(asset) }
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

    /// Adds an imported picture to an asset slot or sheet item session, with the real-person
    /// answer, choosing it if nothing is chosen. Empty if the asset, slot or session is gone.
    public static func appendImportedAssetVersion(image: ImageRef, pixelSize: PixelSize, owner: SessionOwner,
                                                  depictsRealPerson: Bool, to content: inout BookContent,
                                                  versionID: VersionID = VersionID(), now: Date) -> DirtySet {
        guard owner.assetID != nil, let id = sessionID(for: owner, in: content), content.sessions[id] != nil
        else { return DirtySet() }
        content.sessions[id]?.versions.append(Version(id: versionID, image: image, pixelSize: pixelSize,
                                                      source: .imported, createdAt: now,
                                                      depictsRealPerson: depictsRealPerson))
        var dirty = DirtySet(sessions: [id])
        if let asset = chooseIfUnset(versionID, session: id, in: &content) { dirty.assets.insert(asset) }
        return dirty
    }

    /// Sets `chosen` on the slot or sheet item holding `session` if it has none. Returns the
    /// asset changed. The revision follows `Asset.revised(from:)` (primary slot only).
    static func chooseIfUnset(_ version: VersionID, session: SessionID, in content: inout BookContent) -> AssetID? {
        guard let assetID = content.sessions[session]?.owner.assetID, let old = content.assets[assetID] else { return nil }
        var asset = old
        if let i = asset.references.firstIndex(where: { $0.sessionID == session }) {
            guard asset.references[i].chosen == nil else { return nil }
            asset.references[i].chosen = version
        } else if let i = asset.sheet?.items.firstIndex(where: { $0.sessionID == session }) {
            guard asset.sheet?.items[i].chosen == nil else { return nil }
            asset.sheet?.items[i].chosen = version
        } else {
            return nil
        }
        content.assets[assetID] = asset.revised(from: old)
        return assetID
    }

    /// Clears every slot's or sheet item's `chosen` that points at one of `versions` (deleted).
    static func clearAssetChoices(of versions: Set<VersionID>, in content: inout BookContent) -> Set<AssetID> {
        guard !versions.isEmpty else { return [] }
        var changed: Set<AssetID> = []
        for (id, old) in content.assets {
            var asset = old
            for i in asset.references.indices {
                if let chosen = asset.references[i].chosen, versions.contains(chosen) { asset.references[i].chosen = nil }
            }
            if var sheet = asset.sheet {
                for i in sheet.items.indices {
                    if let chosen = sheet.items[i].chosen, versions.contains(chosen) { sheet.items[i].chosen = nil }
                }
                asset.sheet = sheet
            }
            guard asset != old else { continue }
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
