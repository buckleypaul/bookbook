import BBModel
import BBStore
import Foundation

/// The primitive edits behind every `BookCommand`, and the pure functions that apply them to a
/// `BookContent` (A §6.3). Nothing here touches the document's own state.
extension BookDocument {
    // MARK: Edits (internal; each returns its own inverse)

    /// The primitive, invertible edits that commands translate into. Undo and redo replay
    /// these, looking entities up by ID and doing nothing if the target has gone (A §6.3).
    enum Edit: Sendable {
        case setText(page: PageID, box: BoxID, text: RichText?)
        /// `baseline` non-nil also replaces the slot's `acknowledged` (placing a new version
        /// clears its `boxAspect`; the inverse restores the old baseline).
        case setPlacement(page: PageID, box: BoxID, placement: ImagePlacement?, baseline: FlagBaseline? = nil)
        /// AI text styling: the version shown on a text box (nil = unstyled). No-op if the box
        /// has no styling slot or the version is gone.
        case setTextStyle(page: PageID, box: BoxID, version: VersionID?)
        case insertPage(Page, index: Int)
        case removePage(PageID)
        case setTypography(Typography)
        /// Replace `pageOrder` with a permutation of it.
        case setPageOrder([PageID])
        /// Replace an existing page's template, text and slots (template change). Slots keep
        /// their live state: a slot whose session is still on the page takes the current
        /// placement and baseline (so undo keeps a version an AI delivery placed after the
        /// change, Phase 8). The slots' sessions are re-owned by their new boxes, and image
        /// boxes without a slot get one (with an empty session, irreversibly). The inverse is
        /// the page as it was, which re-owns the sessions back.
        case setPageLayout(Page)
        /// Phase 8: set a page's done flag only (so undo touches nothing else).
        case setPageDone(PageID, Bool)
        /// Phase 8: set the zoom and focal point of a placement of `version` (no-op if the box
        /// now shows another version).
        case setCrop(page: PageID, box: BoxID, version: VersionID, zoom: Double, center: NormalizedPoint)
        case setPageNumberStyle(PageNumberStyle)
        /// Phase 7: set the visual style fields and `visualRevision` exactly.
        case setStyleVisual(StyleVisual, revision: Int)
        /// Phase 7: replace the page setup.
        case setPageSetup(PageSetup)
        /// Phase 16: replace the whole style guide (import). Inverse: the old one.
        case setStyleGuide(StyleGuide)
        /// Phase 7: replace the `acknowledged` baselines of the listed image slots.
        case setBaselines(page: PageID, [BoxID: FlagBaseline])
        /// Phase 6: add a template (no-op if the ID exists). Inverse: `removeTemplate`.
        case insertTemplate(Template)
        /// Remove a template (no-op while a page uses it). Inverse: `insertTemplate`.
        case removeTemplate(TemplateID)
        /// Replace an existing template of the same kind. Inverse: the old template.
        case setTemplate(Template)
        /// Phase 10: add an asset (no-op if the ID exists). Inverse: `removeAsset`.
        case insertAsset(Asset)
        /// Remove an asset (no-op if it's gone). Inverse: `insertAsset`.
        case removeAsset(AssetID)
        /// Phase 10: change an existing asset from `from` to `to`, field by field: fields the
        /// edit doesn't change keep their live value, so a reference image a delivery chose in
        /// between survives the undo of a rename (see `BookDocument.mergeAsset`). No-op if the
        /// asset is gone (a deleted asset is never resurrected).
        case updateAsset(from: Asset, to: Asset)
        /// Phase 10: replace a page's asset checklist (IDs of assets that are gone are dropped).
        case setChecklist(page: PageID, [AssetID])
        /// Several edits as one undo step, applied in order; the inverse is the reversed
        /// inverses. A sub-edit whose target has gone is skipped.
        case compound([Edit])
        /// Phase 16b: dismiss (or restore) a version's consistency warning. Inverse: the old value.
        case setConsistencyDismissed(session: SessionID, version: VersionID, dismissed: Bool)
    }

    /// The image files an edit would put back into `content` (style references, asset
    /// reference photos). Versions are not included: replay never restores a deleted version.
    static func imageFileNames(in edit: Edit) -> Set<String> {
        var refs: [ImageRef] = []
        switch edit {
        case let .setStyleVisual(visual, _): refs = visual.styleReferences
        case let .setStyleGuide(guide): refs = guide.styleReferences
        case let .insertAsset(asset): refs = [asset.referencePhoto?.image].compactMap { $0 }
        case let .updateAsset(from, to): refs = [from.referencePhoto?.image, to.referencePhoto?.image].compactMap { $0 }
        case let .compound(edits): return edits.reduce(into: []) { $0.formUnion(imageFileNames(in: $1)) }
        default: return []
        }
        return Set(refs.map(\.fileName))
    }

    /// Applies one edit to `content`, returning its inverse and what changed, or nil if the
    /// target no longer exists. Pure on `content`, so `wouldSplitSpread` can simulate.
    static func applyEdit(_ edit: Edit, to content: inout BookContent) -> (Edit, DirtySet)? {
        switch edit {
        case let .setText(pageID, boxID, text):
            guard content.pages[pageID] != nil else { return nil }
            let old = content.pages[pageID]?.text[boxID]
            content.pages[pageID]?.text[boxID] = text
            return (.setText(page: pageID, box: boxID, text: old), DirtySet(pages: [pageID]))

        case let .setPlacement(pageID, boxID, placement, baseline):
            guard let slot = content.pages[pageID]?.images[boxID] else { return nil }
            // Never point at a version that was deleted (non-undoable) since.
            if let placement, content.sessions[slot.sessionID]?.version(placement.versionID) == nil { return nil }
            content.pages[pageID]?.images[boxID]?.placement = placement
            if let baseline { content.pages[pageID]?.images[boxID]?.acknowledged = baseline }
            return (.setPlacement(page: pageID, box: boxID, placement: slot.placement,
                                  baseline: baseline == nil ? nil : slot.acknowledged),
                    DirtySet(pages: [pageID]))

        case let .setTextStyle(pageID, boxID, versionID):
            guard let slot = content.pages[pageID]?.textStyles[boxID] else { return nil }
            if let versionID, content.sessions[slot.sessionID]?.version(versionID) == nil { return nil }
            content.pages[pageID]?.textStyles[boxID]?.versionID = versionID
            return (.setTextStyle(page: pageID, box: boxID, version: slot.versionID), DirtySet(pages: [pageID]))

        case let .setStyleVisual(visual, revision):
            let old = content.style
            content.style.presetID = visual.presetID
            content.style.visualDescription = visual.visualDescription
            content.style.styleReferences = visual.styleReferences
            content.style.negativeGuidance = visual.negativeGuidance
            content.style.visualRevision = revision
            content.style.visualRevisionHighWater = max(content.style.visualRevisionHighWater, revision)
            return (.setStyleVisual(old.visual, revision: old.visualRevision), DirtySet(style: true))

        case let .setStyleGuide(guide):
            let old = content.style
            content.style = guide
            return (.setStyleGuide(old), DirtySet(style: true))

        case let .setPageSetup(setup):
            let old = content.style.pageSetup
            content.style.pageSetup = setup
            return (.setPageSetup(old), DirtySet(style: true))

        case let .setConsistencyDismissed(sessionID, versionID, dismissed):
            guard let old = content.sessions[sessionID]?.version(versionID)?.consistency?.dismissed else { return nil }
            let dirty = BookMutations.setConsistencyDismissed(dismissed, version: versionID, in: sessionID, to: &content)
            return (.setConsistencyDismissed(session: sessionID, version: versionID, dismissed: old), dirty)

        case let .setBaselines(pageID, baselines):
            guard content.pages[pageID] != nil else { return nil }
            var old: [BoxID: FlagBaseline] = [:]
            for (boxID, baseline) in baselines {
                guard let slot = content.pages[pageID]?.images[boxID] else { continue }
                old[boxID] = slot.acknowledged
                content.pages[pageID]?.images[boxID]?.acknowledged = baseline
            }
            guard !old.isEmpty else { return nil }
            return (.setBaselines(page: pageID, old), DirtySet(pages: [pageID]))

        case let .insertPage(page, index):
            guard content.pages[page.id] == nil, content.templates[page.templateID] != nil else { return nil }
            let at = min(max(0, index), content.book.pageOrder.count)
            content.pages[page.id] = clearingGonePlacements(of: page, in: content)
            content.book.pageOrder.insert(page.id, at: at)
            // A page restored by undoing its deletion may lack slots for image boxes its
            // template gained since (Phase 8).
            let sessions = fillMissingSlots(of: page.id, in: &content)
            return (.removePage(page.id), DirtySet(pages: [page.id], sessions: sessions))

        case let .removePage(pageID):
            guard let index = content.book.pageOrder.firstIndex(of: pageID), let page = content.pages[pageID] else {
                return nil
            }
            content.book.pageOrder.remove(at: index)
            content.pages[pageID] = nil
            return (.insertPage(page, index: index), DirtySet(deletedPages: [pageID]))

        case let .setTypography(typography):
            let old = content.style.typography
            content.style.typography = typography
            return (.setTypography(old), DirtySet(style: true))

        case let .setPageOrder(order):
            // Only a permutation of the current order: pages added or removed since make it stale.
            let old = content.book.pageOrder
            guard order.count == old.count, Set(order) == Set(old) else { return nil }
            content.book.pageOrder = order
            return (.setPageOrder(old), DirtySet(book: true))

        case let .setPageLayout(target):
            guard let old = content.pages[target.id], content.templates[target.templateID] != nil else { return nil }
            var page = target
            // Slots changed outside the undo stack (an AI delivery placing a version) keep that
            // change: match them by session, which is the slot's identity.
            var live: [SessionID: ImageSlot] = [:]
            for slot in old.images.values { live[slot.sessionID] = slot }
            for (boxID, slot) in page.images {
                if let current = live[slot.sessionID] { page.images[boxID] = current }
            }
            // AI text styles stay keyed by box and live (a layout change never edits them; a
            // style on a box the new layout lacks just isn't drawn, and comes back on undo).
            page.textStyles = old.textStyles
            content.pages[page.id] = clearingGonePlacements(of: page, in: content)
            var dirty = DirtySet(pages: [page.id])
            dirty.sessions = fillMissingSlots(of: page.id, in: &content)
            dirty.sessions.formUnion(reownSessions(of: page.id, in: &content))
            return (.setPageLayout(old), dirty)

        case let .setPageDone(pageID, done):
            guard let old = content.pages[pageID]?.isDone else { return nil }
            content.pages[pageID]?.isDone = done
            return (.setPageDone(pageID, old), DirtySet(pages: [pageID]))

        case let .setCrop(pageID, boxID, versionID, zoom, center):
            guard let placement = content.pages[pageID]?.images[boxID]?.placement,
                  placement.versionID == versionID else { return nil }
            content.pages[pageID]?.images[boxID]?.placement?.zoom = zoom
            content.pages[pageID]?.images[boxID]?.placement?.center = center
            return (.setCrop(page: pageID, box: boxID, version: versionID, zoom: placement.zoom,
                             center: placement.center), DirtySet(pages: [pageID]))

        case let .setPageNumberStyle(style):
            let old = content.style.pageNumbers
            content.style.pageNumbers = style
            return (.setPageNumberStyle(old), DirtySet(style: true))

        case let .insertTemplate(template):
            guard content.templates[template.id] == nil else { return nil }
            content.templates[template.id] = template
            return (.removeTemplate(template.id), DirtySet(templates: [template.id]))

        case let .removeTemplate(id):
            guard let old = content.templates[id], content.pages(using: id).isEmpty else { return nil }
            content.templates[id] = nil
            return (.insertTemplate(old), DirtySet(deletedTemplates: [id]))

        case let .setTemplate(template):
            guard let old = content.templates[template.id], old.kind == template.kind else { return nil }
            content.templates[template.id] = template
            return (.setTemplate(old), DirtySet(templates: [template.id]))

        case let .insertAsset(asset):
            guard content.assets[asset.id] == nil else { return nil }
            var restored = asset
            // A chosen version deleted (non-undoable) since isn't brought back: nothing chosen,
            // which is a new revision (the image pages acknowledged is gone).
            if let chosen = asset.chosen, content.sessions[asset.sessionID]?.version(chosen) == nil {
                restored.chosen = nil
                restored = restored.revised(from: asset)
            }
            content.assets[asset.id] = restored
            return (.removeAsset(asset.id), DirtySet(assets: [asset.id]))

        case let .removeAsset(id):
            guard let old = content.assets[id] else { return nil }
            content.assets[id] = nil
            return (.insertAsset(old), DirtySet(deletedAssets: [id]))

        case let .updateAsset(from, to):
            guard let current = content.assets[to.id] else { return nil }
            let merged = mergeAsset(current: current, from: from, to: to) { version in
                content.sessions[current.sessionID]?.version(version) != nil
            }
            guard merged != current else { return nil }
            content.assets[to.id] = merged
            return (.updateAsset(from: merged, to: current), DirtySet(assets: [to.id]))

        case let .setChecklist(pageID, ids):
            guard let old = content.pages[pageID]?.assetChecklist else { return nil }
            let list = ids.filter { content.assets[$0] != nil }
            content.pages[pageID]?.assetChecklist = list
            return (.setChecklist(page: pageID, old), DirtySet(pages: [pageID]))

        case let .compound(edits):
            var inverses: [Edit] = []
            var dirty = DirtySet()
            for edit in edits {
                guard let (inverse, changed) = applyEdit(edit, to: &content) else { continue }
                inverses.append(inverse)
                dirty.formUnion(changed)
            }
            guard !inverses.isEmpty else { return nil }
            return (.compound(inverses.reversed()), dirty)
        }
    }

    /// Three-way merge for `Edit.updateAsset`: start from the live asset and take every field
    /// the edit changes (`from` → `to`); a `chosen` the edit didn't change keeps its live value
    /// (set by a delivery since). Revision: `to`'s when the result matches `to` in description
    /// and choice (undo restores it), else bumped past the high water; the high water never
    /// goes down. `versionExists` says whether a version is still in the asset's session: a
    /// `chosen` deleted (non-undoable) since is never restored; the live choice stays, like
    /// `setPlacement`, and a live choice that is gone is cleared.
    static func mergeAsset(current: Asset, from: Asset, to: Asset,
                           versionExists: (VersionID) -> Bool = { _ in true }) -> Asset {
        var out = current
        if to.name != from.name { out.name = to.name }
        if to.description != from.description { out.description = to.description }
        if to.chosen != from.chosen, to.chosen.map(versionExists) ?? true { out.chosen = to.chosen }
        if let chosen = out.chosen, !versionExists(chosen) { out.chosen = nil }
        if to.referencePhoto != from.referencePhoto { out.referencePhoto = to.referencePhoto }
        let highWater = max(current.revisionHighWater, from.revisionHighWater, to.revisionHighWater)
        if out.description == to.description, out.chosen == to.chosen {
            out.revision = to.revision
            out.revisionHighWater = highWater
        } else {
            // Something the edit didn't touch moved meanwhile: a fresh number past the high water.
            out.revisionHighWater = highWater
            out = out.revised(from: current)
        }
        return out
    }

    /// `page` with every placement whose version is no longer in its slot's session removed
    /// (deleted, non-undoably, since the page was taken off the book or changed layout).
    private static func clearingGonePlacements(of page: Page, in content: BookContent) -> Page {
        var page = page
        for (boxID, slot) in page.images {
            if let placement = slot.placement, content.sessions[slot.sessionID]?.version(placement.versionID) == nil {
                page.images[boxID]?.placement = nil
            }
        }
        return page
    }

    /// Gives every image box of the page's template that has no slot an empty slot and session
    /// (as `updateTemplate` does for the pages using a template). Irreversible: the sessions
    /// stay behind as orphans if the page goes again. Returns the new sessions.
    private static func fillMissingSlots(of pageID: PageID, in content: inout BookContent) -> Set<SessionID> {
        guard let page = content.pages[pageID], let template = content.template(for: page) else { return [] }
        var created: Set<SessionID> = []
        for box in template.imageBoxes where page.images[box.id] == nil {
            let (session, slot) = emptySlot(page: pageID, box: box.id)
            content.sessions[session.id] = session
            content.pages[pageID]?.images[box.id] = slot
            created.insert(session.id)
        }
        return created
    }

    /// A new empty session for an image box, and the slot pointing at it.
    static func emptySlot(page: PageID, box: BoxID) -> (session: Session, slot: ImageSlot) {
        let session = Session(owner: .pageBox(page, box))
        return (session, ImageSlot(sessionID: session.id))
    }

    /// Points each slot's session at the box now holding it (`.pageBox(page, box)`), so
    /// in-flight requests and context assembly resolve the moved slot (Phase 8). Returns the
    /// sessions changed.
    private static func reownSessions(of pageID: PageID, in content: inout BookContent) -> Set<SessionID> {
        guard let page = content.pages[pageID] else { return [] }
        var changed: Set<SessionID> = []
        for (boxID, slot) in page.images {
            let owner = SessionOwner.pageBox(pageID, boxID)
            guard let session = content.sessions[slot.sessionID], session.owner != owner else { continue }
            content.sessions[slot.sessionID]?.owner = owner
            changed.insert(slot.sessionID)
        }
        return changed
    }
}
