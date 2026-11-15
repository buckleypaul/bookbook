import BBLayout
import BBModel
import BBStore
import Foundation

/// Translating a `BookCommand` into its `Edit` (A §6.3). Reads `content`, never writes it.
extension BookDocument {
    /// A command translated into its undoable edit, plus what it creates irreversibly
    /// (A §6.3): empty sessions for new image boxes, and bundled presets copied into the book.
    /// Both stay behind as harmless orphans if the edit is undone. A package can't drop a
    /// template file (`DirtySet` has no template deletions), so preset copy-in is deliberately
    /// outside the undo step.
    struct Prepared {
        var edit: Edit
        var sessions: [SessionID: Session] = [:]
        var templates: [TemplateID: Template] = [:]
        /// Image slots (with the sessions above) for image boxes new to a template, on the pages
        /// using it. Added irreversibly; an existing slot is never replaced.
        var slots: [PageID: [BoxID: ImageSlot]] = [:]
    }

    /// Translates `command` without mutating anything. Nil if its target doesn't exist or it
    /// would change nothing.
    func prepare(_ command: BookCommand) -> Prepared? {
        var created = Prepared(edit: .compound([]))
        var fixSplits = false
        let edit: Edit

        switch command {
        case let .setStyleVisual(visual):
            guard visual != content.style.visual else { return nil }
            let revision = content.style.applying(visual).visualRevision
            edit = .setStyleVisual(visual, revision: revision)

        case let .setPageSetup(setup):
            guard setup != content.style.pageSetup else { return nil }
            edit = .setPageSetup(setup)

        case let .importFromBook(imported):
            var edits: [Edit] = []
            for template in imported.templates where content.templates[template.id] == nil {
                edits.append(.insertTemplate(template))
            }
            for asset in imported.assets where content.assets[asset.id] == nil {
                edits.append(.insertAsset(asset))
            }
            let newAssets = Set(imported.assets.filter { content.assets[$0.id] == nil }.map(\.id))
            for session in imported.sessions where content.sessions[session.id] == nil {
                if let owner = session.owner.assetID, newAssets.contains(owner) {
                    created.sessions[session.id] = session
                }
            }
            if let guide = imported.styleGuide {
                var next = guide
                next.pageSetup = content.style.pageSetup
                next.pageNumbers = content.style.pageNumbers
                next.visualRevision = content.style.visualRevision
                next.visualRevisionHighWater = content.style.visualRevisionHighWater
                if guide.visualDescription != content.style.visualDescription
                    || guide.styleReferences != content.style.styleReferences
                    || guide.negativeGuidance != content.style.negativeGuidance {
                    next.visualRevision = content.style.visualRevisionHighWater + 1
                    next.visualRevisionHighWater = next.visualRevision
                }
                if next != content.style { edits.append(.setStyleGuide(next)) }
            }
            guard !edits.isEmpty else { return nil }
            edit = .compound(edits)

        case let .markFlagsOK(pageID, boxID):
            guard let page = content.pages[pageID], let template = content.template(for: page) else { return nil }
            var baselines: [BoxID: FlagBaseline] = [:]
            var dismissals: [Edit] = []
            for box in template.imageBoxes where boxID == nil || box.id == boxID {
                guard var slot = page.images[box.id], let placement = slot.placement else { continue }
                slot.acknowledged.styleRevision = content.style.visualRevision
                slot.acknowledged.boxAspect = content.boxAspect(box, in: template)
                // Phase 10: accept the current revision of every asset the image was made with.
                let used = content.sessions[slot.sessionID]?.version(placement.versionID)?.provenance?.assetRevisions
                for asset in (used ?? [:]).keys {
                    if let revision = content.assets[asset]?.revision { slot.acknowledged.assetRevisions[asset] = revision }
                }
                if slot.acknowledged != page.images[box.id]?.acknowledged { baselines[box.id] = slot.acknowledged }
                // Also clear the placed version's consistency warning (Phase 16b).
                if content.sessions[slot.sessionID]?.version(placement.versionID)?.consistency?.showsWarning == true {
                    dismissals.append(.setConsistencyDismissed(session: slot.sessionID, version: placement.versionID,
                                                               dismissed: true))
                }
            }
            guard !baselines.isEmpty || !dismissals.isEmpty else { return nil }
            edit = .compound((baselines.isEmpty ? [] : [.setBaselines(page: pageID, baselines)]) + dismissals)

        case let .setRichText(pageID, boxID, text, _):
            guard let page = content.pages[pageID], let template = content.template(for: page),
                  let box = template.box(boxID), case .text = box.content else { return nil }
            edit = .setText(page: pageID, box: boxID, text: text)

        case let .chooseVersion(pageID, boxID, versionID):
            guard let page = content.pages[pageID], let template = content.template(for: page),
                  let box = template.box(boxID), let slot = page.images[boxID],
                  content.sessions[slot.sessionID]?.version(versionID) != nil else { return nil }
            if slot.placement?.versionID == versionID { return nil }
            let placement = ImagePlacement(versionID: versionID, boxAspectWhenPlaced: content.boxAspect(box, in: template))
            // A different picture starts unacknowledged: the old one's "OK" doesn't carry over (A §4.4).
            let baseline = FlagBaseline()
            edit = .setPlacement(page: pageID, box: boxID, placement: placement, baseline: baseline)

        case let .chooseTextStyle(pageID, boxID, versionID):
            guard let slot = content.pages[pageID]?.textStyles[boxID], slot.versionID != versionID else { return nil }
            if let versionID, content.sessions[slot.sessionID]?.version(versionID)?.textStyle == nil { return nil }
            edit = .setTextStyle(page: pageID, box: boxID, version: versionID)

        case let .addPage(index, templateID, fix):
            guard let template = resolveTemplate(templateID, into: &created), PageKind.story.accepts(template.kind)
            else { return nil }
            let page = BookContent.makePage(kind: .story, template: template, sessions: &created.sessions)
            edit = .insertPage(page, index: clamped(index))
            fixSplits = fix

        case let .duplicatePage(pageID, fix):
            guard let index = content.book.pageOrder.firstIndex(of: pageID), let source = content.pages[pageID]
            else { return nil }
            edit = .insertPage(duplicate(source, sessions: &created.sessions), index: index + 1)
            fixSplits = fix

        case let .deletePage(pageID, fix):
            guard content.book.pageOrder.contains(pageID) else { return nil }
            edit = .removePage(pageID)
            fixSplits = fix

        case let .reorderPages(order, fix):
            let current = content.book.pageOrder
            guard order.count == current.count, Set(order).count == order.count, Set(order) == Set(current)
            else { return nil }
            edit = .setPageOrder(order)
            fixSplits = fix

        case let .setPageTemplate(pageID, templateID, fix):
            guard let page = content.pages[pageID], page.templateID != templateID,
                  let old = content.template(for: page),
                  let new = resolveTemplate(templateID, into: &created),
                  page.kind.accepts(new.kind) else { return nil }
            let result = TemplateReassignment.reassign(page, from: old, to: new)
            var changed = result.page
            for boxID in result.unassignedImageBoxes {
                let (session, slot) = Self.emptySlot(page: pageID, box: boxID)
                created.sessions[session.id] = session
                changed.images[boxID] = slot
            }
            edit = .setPageLayout(changed)
            fixSplits = fix

        case let .importStoryText(texts, templateID, index, fix):
            guard !texts.isEmpty, let template = resolveTemplate(templateID, into: &created),
                  PageKind.story.accepts(template.kind), let textBox = Self.firstTextBox(of: template) else { return nil }
            let start = clamped(index)
            var inserts: [Edit] = []
            for (offset, text) in texts.enumerated() {
                var page = BookContent.makePage(kind: .story, template: template, sessions: &created.sessions)
                page.text[textBox] = text
                inserts.append(.insertPage(page, index: start + offset))
            }
            edit = .compound(inserts)
            fixSplits = fix

        case let .setPageDone(pageID, done):
            guard let page = content.pages[pageID], page.isDone != done else { return nil }
            edit = .setPageDone(pageID, done)

        case let .setCrop(pageID, boxID, zoom, center):
            guard let page = content.pages[pageID], let template = content.template(for: page),
                  let box = template.box(boxID), box.content == .image,
                  let placement = page.images[boxID]?.placement,
                  let version = content.placedVersion(page: pageID, box: boxID) else { return nil }
            let boxRect = PageGeometry(setup: content.style.pageSetup, kind: template.kind).renderRect(for: box)
            let imageSize = CGSize(width: version.pixelSize.width, height: version.pixelSize.height)
            let crop = CropMath.clamped(zoom: zoom, center: center, imageSize: imageSize, boxRect: boxRect)
            if CropMath.isSame(crop, (placement.zoom, placement.center)) { return nil }
            edit = .setCrop(page: pageID, box: boxID, version: placement.versionID, zoom: crop.zoom, center: crop.center)

        case let .addAsset(asset):
            guard content.assets[asset.id] == nil else { return nil }
            addMissingSessions(of: asset, to: &created)
            edit = .insertAsset(asset)

        case let .updateAsset(asset, _):
            guard let old = content.assets[asset.id] else { return nil }
            var proposed = asset
            proposed.id = old.id
            proposed.type = old.type
            proposed.sessionID = old.sessionID
            let stored = proposed.revised(from: old)
            guard stored != old else { return nil }
            addMissingSessions(of: stored, to: &created)
            edit = .updateAsset(from: old, to: stored)

        case let .setAssetChecklist(pageID, ids):
            guard let page = content.pages[pageID] else { return nil }
            var seen: Set<AssetID> = []
            let list = ids.filter { content.assets[$0] != nil && seen.insert($0).inserted }
            guard list != page.assetChecklist else { return nil }
            edit = .setChecklist(page: pageID, list)

        case let .setTypography(typography):
            edit = .setTypography(typography)

        case let .setPageNumberStyle(style):
            guard style != content.style.pageNumbers else { return nil }
            edit = .setPageNumberStyle(style)

        case let .addTemplate(template):
            guard content.templates[template.id] == nil else { return nil }
            edit = .insertTemplate(template)

        case let .updateTemplate(template, _):
            guard let old = content.templates[template.id], old.kind == template.kind, old != template
            else { return nil }
            let oldBoxes = Set(old.boxes.map(\.id))
            for box in template.imageBoxes where !oldBoxes.contains(box.id) {
                for pageID in content.pages(using: template.id) {
                    guard content.pages[pageID]?.images[box.id] == nil else { continue }
                    let (session, slot) = Self.emptySlot(page: pageID, box: box.id)
                    created.sessions[session.id] = session
                    created.slots[pageID, default: [:]][box.id] = slot
                }
            }
            edit = .setTemplate(template)

        case let .deleteTemplate(id):
            guard content.templates[id] != nil, content.pages(using: id).isEmpty else { return nil }
            edit = .removeTemplate(id)
        }

        created.edit = edit
        if fixSplits {
            guard let blanks = blankInsertions(after: &created) else { return nil }
            if !blanks.isEmpty { created.edit = .compound([edit] + blanks) }
        }
        if case let .setPageOrder(order) = created.edit, order == content.book.pageOrder { return nil }
        return created
    }

    /// The edits that insert blank text-only pages so `prepared` leaves no spread split
    /// (A §8.1, applied after its edit), adding the blank template and pages' sessions to
    /// `prepared`. Nil if the text-only preset can't be found.
    private func blankInsertions(after prepared: inout Prepared) -> [Edit]? {
        var copy = content
        Self.merge(prepared, into: &copy)
        guard Self.applyEdit(prepared.edit, to: &copy) != nil else { return [] }
        let insertions = PageSequencer.blankInsertions(for: Self.sequence(of: copy))
        guard !insertions.isEmpty else { return [] }
        guard let blank = resolveTemplate(Presets.textOnlyTemplateID, into: &prepared) else { return nil }
        var edits: [Edit] = []
        for index in insertions {
            let page = BookContent.makePage(kind: .story, template: blank, sessions: &prepared.sessions)
            edits.append(.insertPage(page, index: index))
        }
        return edits
    }

    /// The book's template, else the bundled preset with that ID (recorded in `prepared`, to
    /// be copied in).
    private func resolveTemplate(_ id: TemplateID, into prepared: inout Prepared) -> Template? {
        if let template = content.templates[id] ?? prepared.templates[id] { return template }
        guard let preset = try? Presets.template(id) else { return nil }
        prepared.templates[id] = preset
        return preset
    }

    /// An empty session (irreversible) for the asset if it has none yet (a new asset, or a
    /// legacy asset whose session file never existed).
    private func addMissingSessions(of asset: Asset, to prepared: inout Prepared) {
        guard content.sessions[asset.sessionID] == nil else { return }
        prepared.sessions[asset.sessionID] = Session(id: asset.sessionID, owner: asset.owner)
    }

    private func clamped(_ index: Int) -> Int { min(max(0, index), content.book.pageOrder.count) }

    /// A copy of `source` under a new ID: same template, text, checklist and placements, each
    /// image box's session copied under a new ID (versions keep their IDs, so placements still
    /// resolve; images are content-addressed, so no files are copied). Not done.
    private func duplicate(_ source: Page, sessions: inout [SessionID: Session]) -> Page {
        var page = source
        page.id = PageID()
        page.isDone = false
        /// The session copied under a new ID for `owner` (empty if the original is missing).
        func copy(_ id: SessionID, owner: SessionOwner) -> Session {
            var session = content.sessions[id] ?? Session(owner: owner)
            session.id = SessionID()
            session.owner = owner
            // Requests still in flight deliver to the original session only.
            for i in session.messages.indices { session.messages[i].queueItemID = nil }
            return session
        }
        for (boxID, slot) in source.images {
            let session = copy(slot.sessionID, owner: .pageBox(page.id, boxID))
            sessions[session.id] = session
            page.images[boxID]?.sessionID = session.id
            if let placement = slot.placement, session.version(placement.versionID) == nil {
                page.images[boxID]?.placement = nil
            }
        }
        // AI text styles (A §7.13): each styled box's session is copied the same way.
        for (boxID, slot) in source.textStyles {
            let session = copy(slot.sessionID, owner: .textBox(page.id, boxID))
            sessions[session.id] = session
            page.textStyles[boxID]?.sessionID = session.id
            if let shown = slot.versionID, session.version(shown) == nil { page.textStyles[boxID]?.versionID = nil }
        }
        return page
    }

    /// The template's first text box in reading order, by the rule `TemplateReassignment` uses
    /// (story import, PD §8.5): reassigning one role-less text box onto `template` puts its
    /// text in exactly that box.
    private static func firstTextBox(of template: Template) -> BoxID? {
        let probe = Box(frame: NormalizedRect(x: 0, y: 0, width: 1, height: 1), content: .text(TextBoxStyle()))
        let source = Template(name: "", kind: template.kind, boxes: [probe])
        let page = Page(kind: .story, templateID: source.id, text: [probe.id: RichText(plain: "x")])
        return TemplateReassignment.reassign(page, from: source, to: template).page.text.keys.first
    }

    /// The story order as the sequencer sees it: one entry per `pageOrder` ID. Unlike
    /// `PageSequencer.entries(for:)`, an ID whose page is missing still gets an entry (as a
    /// single page), so `blankInsertions` indices stay indices into `pageOrder`.
    private static func sequence(of content: BookContent) -> [SequenceEntry] {
        content.book.pageOrder.map { id in
            SequenceEntry(id: id, isSpread: content.pages[id].map(content.isSpread) ?? false)
        }
    }

    static func merge(_ prepared: Prepared, into content: inout BookContent) {
        content.sessions.merge(prepared.sessions) { current, _ in current }
        content.templates.merge(prepared.templates) { current, _ in current }
        for (pageID, slots) in prepared.slots {
            for (boxID, slot) in slots where content.pages[pageID]?.images[boxID] == nil {
                content.pages[pageID]?.images[boxID] = slot
            }
        }
    }

    /// True when performing `command` (with `fixSplits: false`) would leave a spread split
    /// across two sheets (PD §8.5). The UI then warns and offers the `fixSplits: true`
    /// variant. False for non-structural commands.
    ///
    /// Simulates the command on a copy of the content; nothing is mutated or saved. A book whose
    /// order is already split (and stays split) answers true for any structural command.
    public func wouldSplitSpread(_ command: BookCommand) -> Bool {
        guard command.isStructural, let prepared = prepare(command.withFixSplits(false)) else { return false }
        var copy = content
        Self.merge(prepared, into: &copy)
        guard Self.applyEdit(prepared.edit, to: &copy) != nil else { return false }
        // Only a split the command creates counts: a book the user already accepted as split
        // doesn't warn again (Phase 16b).
        func splits(_ c: BookContent) -> Set<PageID> {
            Set(PageSequencer.layout(Self.sequence(of: c), cover: c.book.coverPageID).pages.filter(\.isSplit).map(\.id))
        }
        return !splits(copy).subtracting(splits(content)).isEmpty
    }
}
