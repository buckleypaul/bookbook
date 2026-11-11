import BBAI
import BBModel
import BBStore
import Foundation

/// AI text styling (A §7.13): the non-undoable session mutations for a page text box's styling
/// session. Choosing a version is undoable (`BookCommand.chooseTextStyle`).
extension BookMutations {
    /// Gives `page`'s text box `box` a styling session and slot if it has none. Empty if the page
    /// is gone, the box isn't one of its template's text boxes, or it already has a slot.
    public static func ensureTextStyleSlot(page pageID: PageID, box boxID: BoxID,
                                           to content: inout BookContent) -> DirtySet {
        guard let page = content.pages[pageID], page.textStyles[boxID] == nil,
              let box = content.template(for: page)?.box(boxID), case .text = box.content else { return DirtySet() }
        let session = Session(owner: .textBox(pageID, boxID))
        content.sessions[session.id] = session
        content.pages[pageID]?.textStyles[boxID] = TextStyleSlot(sessionID: session.id)
        return DirtySet(pages: [pageID], sessions: [session.id])
    }

    /// A finished decoration: the version goes into the styling session (found by message
    /// first) and is shown on the box (the newest style always wins, like an asset's image;
    /// choosing an older one is undoable).
    static func applyTextStyleDelivery(_ delivery: GenerationDelivery, storedImage: ImageRef?,
                                       to content: inout BookContent, versionID: VersionID, now: Date) -> DirtySet {
        let owner = delivery.item.target.owner
        guard let sessionID = content.session(containing: delivery.item.messageID)?.id
                ?? Self.sessionID(for: owner, in: content),
              var session = content.sessions[sessionID] else { return DirtySet() }
        var dirty = DirtySet()
        let (changed, delivered) = record(delivery, storedImage: storedImage, versionID: versionID, now: now,
                                          in: &session, content: content)
        if changed { dirty.sessions.insert(sessionID) }
        content.sessions[sessionID] = session
        if let version = delivered, let page = show(version.id, session: sessionID, in: &content) {
            dirty.pages.insert(page)
        }
        return dirty
    }

    /// A typography-only style (no decoration, so no image request): appends the user's message
    /// and a version whose image is a 1×1 transparent placeholder, and shows it. Empty if the
    /// box has no styling session.
    public static func appendTypographyOnlyStyle(message: Message, intent: GenerationIntent, placeholder: ImageRef,
                                                 page pageID: PageID, box boxID: BoxID, to content: inout BookContent,
                                                 versionID: VersionID = VersionID(), now: Date) -> DirtySet {
        guard let sessionID = content.pages[pageID]?.textStyles[boxID]?.sessionID,
              var session = content.sessions[sessionID], let call = intent.textStyle?.call else { return DirtySet() }
        var message = message
        message.epoch = session.resetEpoch
        message.queueItemID = nil
        message.producedVersion = versionID
        session.messages.append(message)
        let provenance = Provenance(provider: call.provider, model: call.model, quality: intent.quality,
                                    outputSize: PixelSize(width: 1, height: 1), promptSent: "",
                                    styleRevision: content.style.visualRevision, storyTextIncluded: false,
                                    intent: intent, cost: call.cost, usage: call.usage,
                                    parametersSent: call.parametersSent)
        session.versions.append(Version(id: versionID, image: placeholder, pixelSize: PixelSize(width: 1, height: 1),
                                        source: .generated, parent: intent.refines, createdAt: now,
                                        provenance: provenance))
        content.sessions[sessionID] = session
        var dirty = DirtySet(sessions: [sessionID])
        if let page = show(versionID, session: sessionID, in: &content) { dirty.pages.insert(page) }
        return dirty
    }

    /// Shows `version` on whichever page text box holds `session`. Returns the page changed.
    private static func show(_ version: VersionID, session: SessionID, in content: inout BookContent) -> PageID? {
        for (pageID, page) in content.pages {
            for (boxID, slot) in page.textStyles where slot.sessionID == session {
                guard slot.versionID != version else { return nil }
                content.pages[pageID]?.textStyles[boxID]?.versionID = version
                return pageID
            }
        }
        return nil
    }

    /// Unstyles every text box showing one of `versions`.
    static func clearTextStyles(of versions: Set<VersionID>, in content: inout BookContent) -> Set<PageID> {
        var changed: Set<PageID> = []
        for (pageID, page) in content.pages {
            for (boxID, slot) in page.textStyles {
                guard let shown = slot.versionID, versions.contains(shown) else { continue }
                content.pages[pageID]?.textStyles[boxID]?.versionID = nil
                changed.insert(pageID)
            }
        }
        return changed
    }
}
