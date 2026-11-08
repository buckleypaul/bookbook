import BBLayout
import BBModel
import BBStore
import Foundation
import Observation

/// One open book (A §6.1, §6.3). Holds the in-memory value tree, its `BookStore`, and the
/// command layer. Every undoable edit goes through `perform(_:)`; AI results and other
/// non-undoable writes go through `performIrreversible(_:)`.
///
/// A book held by another BookBook opens read-only (A §5.3): `perform` and `performIrreversible`
/// do nothing and nothing is written. After `close()` they do nothing either.
///
/// HOT SPOT (plan §2.5): only the main thread edits this file.
@MainActor @Observable
public final class BookDocument {
    public let id: BookID
    public private(set) var content: BookContent
    /// The last autosave failure, shown by the window. Cleared by the next successful flush.
    public private(set) var lastSaveError: StoreError?
    /// Opened read-only because another process holds the book's lock.
    public let isReadOnly: Bool
    /// Set by `close()`; edits are ignored from then on.
    public private(set) var isClosed = false
    /// Phase 4: the window's format bar / Format menu state, driven by the inline text editor.
    public let formatting = TextFormatController()
    /// Phase 4: PostScript names the book uses that don't resolve (book-level warning, A §8.3).
    /// Refreshed when the book opens, after a font import and after every undoable edit except
    /// coalesced typing (which reuses the formatting already there).
    public private(set) var missingFonts: [String] = []
    /// Bumped after a font import, so cached text layouts that resolved
    /// a font before it was registered can be thrown away (the canvas watches this).
    public private(set) var fontsRevision = 0

    @ObservationIgnored public let store: BookStore
    /// The window's undo manager (SwiftUI `@Environment(\.undoManager)`), set by the window.
    @ObservationIgnored public weak var undoManager: UndoManager?
    @ObservationIgnored private var saveChain: Task<Void, Never>?
    @ObservationIgnored private var autosaveResults: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let now: () -> Date
    /// Coalesces consecutive typing into one undo step (A §6.3).
    @ObservationIgnored private var typing: TypingCoalescer
    /// The undo manager the open typing step was registered with.
    @ObservationIgnored private weak var typingUndoManager: UndoManager?

    // Library thumbnail (A §5.1): rewritten at most every `thumbnailInterval` after a change,
    // and on flush and close, never on the typing path.
    @ObservationIgnored private let thumbnailInterval: Duration
    @ObservationIgnored private var thumbnailTask: Task<Void, Never>?
    @ObservationIgnored private(set) var thumbnailDirty = false
    /// Renders `thumbnail.png`. Tests replace it.
    @ObservationIgnored var renderThumbnail: @MainActor (BookContent, BookStore) -> Data? = { content, store in
        BookThumbnail.png(for: content, imageURL: { store.imageURL(for: $0) })
    }

    public init(content: BookContent, store: BookStore, readOnly: Bool = false,
                thumbnailInterval: Duration = .seconds(3), now: @escaping () -> Date = { Date() }) {
        self.id = content.book.id
        self.content = content
        self.store = store
        self.isReadOnly = readOnly
        self.thumbnailInterval = thumbnailInterval
        self.now = now
        self.typing = TypingCoalescer(clock: now)
        // Report every autosave result (timer-fired or flushed) so the window's banner shows a
        // failure within about a second, not only at close. First link of the save chain, so
        // it's installed before any save is scheduled.
        let (results, continuation) = AsyncStream.makeStream(of: StoreError?.self)
        saveChain = Task {
            await store.setAutosaveResultHandler { continuation.yield($0) }
        }
        autosaveResults = Task { [weak self] in
            for await error in results { self?.lastSaveError = error }
        }
        // Imported fonts (A §8.3): every file in `fonts/` is registered for this process.
        FontRegistry.register(store.fontFileURLs())
        refreshMissingFonts()
    }

    isolated deinit {
        autosaveResults?.cancel()
        thumbnailTask?.cancel()
    }

    /// Takes the book's lock, then loads the package at `url` (rolling the journal forward first).
    /// Throws `.locked(owner)` if another live process holds the lock. With `readOnly`, it doesn't
    /// take the lock and nothing is ever written.
    public static func open(at url: URL, readOnly: Bool = false) async throws(StoreError) -> BookDocument {
        let store = BookStore(packageURL: url)
        if readOnly {
            await store.setReadOnly()
        } else if case let .heldByOther(owner) = try await store.acquireLock() {
            throw .locked(owner)
        }
        let content: BookContent
        do {
            content = try await store.load()
        } catch {
            await store.releaseLock()
            throw error
        }
        let document = BookDocument(content: content, store: store, readOnly: readOnly)
        // A book that has never had a library thumbnail (new, or copied in) gets one soon.
        if !readOnly, !FileManager.default.fileExists(atPath: store.thumbnailURL.path(percentEncoded: false)) {
            document.markThumbnailDirty()
        }
        return document
    }

    /// False while read-only or closed.
    public var isEditable: Bool { !isReadOnly && !isClosed }

    /// Phase 4 contract: imports a font file into `fonts/`, registers it for this process and
    /// refreshes `missingFonts`. Not undoable (PD §8.10). Returns the inspected info so the
    /// caller can warn when `embeddingAllowed` is false. Throws for unreadable files.
    public func importFont(from url: URL) async throws -> FontFileInfo {
        guard isEditable else { throw StoreError.readOnly }
        let info = try FontInspector.inspect(url)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw FontError.unreadable(url.lastPathComponent)
        }
        let stored = try await store.storeFont(data, fileExtension: url.pathExtension.lowercased())
        // A failed registration only matters if the font still doesn't resolve (registering a
        // copy of an installed font can fail as a duplicate, and the font is usable anyway).
        if let failure = FontRegistry.register([stored])[stored],
           !info.postScriptNames.contains(where: FontAvailability.isAvailable(postScriptName:)) {
            throw failure
        }
        fontsRevision += 1
        refreshMissingFonts()
        return info
    }

    /// Recomputes `missingFonts` over every page's text and the style's typography.
    private func refreshMissingFonts() {
        let texts = content.book.pageOrder.flatMap { id in
            (content.pages[id]?.text.values).map(Array.init) ?? []
        }
        let missing = FontAvailability.missingFonts(in: texts, typography: content.style.typography)
        if missing != missingFonts { missingFonts = missing }
    }

    /// Ends the open typing undo step, so the next keystroke starts a new one (the editor
    /// closing, for example).
    public func endTypingStep() {
        typing.close()
    }

    // MARK: Undoable edits

    /// Applies an undoable command and registers its inverse. Returns false (and registers
    /// nothing) if the command's target doesn't exist, or the book is read-only or closed.
    @discardableResult
    public func perform(_ command: BookCommand) -> Bool {
        guard isEditable, let prepared = prepare(command) else {
            typing.close()
            return false
        }
        let edit = prepared.edit
        commitIrreversibleParts(of: prepared)
        // A typing edit that joins the open step changes the content but registers nothing: the
        // step's undo entry still restores the text from before the step began (A §6.3).
        let sameManager = typingUndoManager != nil && typingUndoManager === undoManager
        if typing.shouldCoalesce(command), sameManager, var (_, dirty) = applyEdit(edit) {
            content.book.modifiedAt = now()
            dirty.book = true
            scheduleSave(dirty)
            return true
        }
        guard apply(edit, actionName: command.actionName) else {
            typing.close()
            return false
        }
        typingUndoManager = undoManager
        return true
    }

    // MARK: Undo groups (Phase 6: one undo step per drag, A §6.3)

    /// Opens an undo group (mouse-down of a drag, resize or rotation). Until
    /// `endUndoGroup(actionName:)`, every successful `perform` applies its edit and saves as
    /// usual (pages update live) but registers no undo; the group's inverses are collected.
    /// Closes any open typing step. Nested calls are ignored (the outer group wins).
    public func beginUndoGroup() {
        fatalError("Phase 6 lane L1")
    }

    /// Closes the open group (mouse-up) and registers one undo step named `actionName` that
    /// restores everything from before `beginUndoGroup()`. Registers nothing if no edit was
    /// performed in the group. No-op without an open group.
    public func endUndoGroup(actionName: String) {
        fatalError("Phase 6 lane L1")
    }

    /// For non-undoable writes (A §6.3): AI results, session changes, renaming the book. Never
    /// registers undo. `body` returns what it changed. Does nothing if read-only or closed.
    public func performIrreversible(_ body: (inout BookContent) -> DirtySet) {
        guard isEditable else { return }
        var dirty = body(&content)
        guard !dirty.isEmpty else { return }
        content.book.modifiedAt = now()
        dirty.book = true
        scheduleSave(dirty)
    }

    /// True when performing `command` (with `fixSplits: false`) would leave a spread split
    /// across two sheets (PD §8.5). The UI then warns and offers the `fixSplits: true`
    /// variant. False for non-structural commands.
    ///
    /// Simulates the command on a copy of the content; nothing is mutated or saved. A book whose
    /// order is already split (and stays split) answers true for any structural command.
    public func wouldSplitSpread(_ command: BookCommand) -> Bool {
        let unfixed: BookCommand
        switch command {
        case let .addPage(index, templateID, _): unfixed = .addPage(index: index, templateID: templateID)
        case let .duplicatePage(id, _): unfixed = .duplicatePage(id)
        case let .deletePage(id, _): unfixed = .deletePage(id)
        case let .reorderPages(order, _): unfixed = .reorderPages(order)
        case let .setPageTemplate(page, templateID, _): unfixed = .setPageTemplate(page: page, templateID: templateID)
        case let .importStoryText(texts, templateID, index, _):
            unfixed = .importStoryText(texts, templateID: templateID, index: index)
        case .setRichText, .setTypography, .chooseVersion, .setPageDone, .setPageNumberStyle,
             .addTemplate, .updateTemplate, .deleteTemplate:
            return false
        }
        guard let prepared = prepare(unfixed) else { return false }
        var copy = content
        Self.merge(prepared, into: &copy)
        guard Self.applyEdit(prepared.edit, to: &copy) != nil else { return false }
        return PageSequencer.layout(Self.sequence(of: copy), cover: copy.book.coverPageID).hasSplitSpread
    }

    /// Book Settings (PD §8.12): set the author. Not undoable, like `rename(to:)`; the cover
    /// redraws from `content.book`. Returns false for a read-only book.
    @discardableResult
    public func setAuthor(_ author: String) -> Bool {
        let author = author.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isEditable else { return false }
        performIrreversible { content in
            guard content.book.author != author else { return DirtySet() }
            content.book.author = author
            return DirtySet(book: true)
        }
        return true
    }

    /// Renames the book (`Book.title`; the package folder keeps its name). Not undoable
    /// (PD §8.10). Returns false if the title is empty or the book can't be edited.
    @discardableResult
    public func rename(to title: String) -> Bool {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isEditable, !title.isEmpty else { return false }
        performIrreversible { content in
            guard content.book.title != title else { return DirtySet() }
            content.book.title = title
            return DirtySet(book: true)
        }
        return true
    }

    // MARK: Saving

    /// Writes any pending autosave now (window close, quit, hide), then the library thumbnail if
    /// it's out of date.
    public func flush() async {
        let pending = saveChain
        await pending?.value
        do {
            try await store.flush()
            lastSaveError = nil
        } catch {
            lastSaveError = error
        }
        await writeThumbnailIfNeeded()
    }

    /// Stops editing, flushes, writes the thumbnail and releases the lock (window close, quit).
    /// Safe to call more than once.
    public func close() async {
        isClosed = true
        await flush()
        await store.releaseLock()
    }

    private func scheduleSave(_ dirty: DirtySet) {
        generation += 1
        let snapshot = content, gen = generation, store = store
        let previous = saveChain
        // Chained so snapshots reach the store in order.
        saveChain = Task {
            await previous?.value
            await store.scheduleSave(snapshot, dirty: dirty, generation: gen)
        }
        markThumbnailDirty()
    }

    // MARK: Thumbnail

    /// Notes that the thumbnail is out of date and, if no write is waiting, schedules one after
    /// `thumbnailInterval` (so at most one write per interval, whatever the edit rate).
    private func markThumbnailDirty() {
        guard !isReadOnly else { return }
        thumbnailDirty = true
        guard thumbnailTask == nil else { return }
        let interval = thumbnailInterval
        thumbnailTask = Task { [weak self] in
            do { try await Task.sleep(for: interval) } catch { return }
            await self?.thumbnailTimerFired()
        }
    }

    private func thumbnailTimerFired() async {
        thumbnailTask = nil
        await writeThumbnailIfNeeded()
    }

    private func writeThumbnailIfNeeded() async {
        guard thumbnailDirty, !isReadOnly else { return }
        thumbnailTask?.cancel()
        thumbnailTask = nil
        thumbnailDirty = false
        guard let png = renderThumbnail(content, store) else { return }
        // A rebuildable cache: a failed write is retried after the next change.
        do { try await store.writeThumbnail(png) } catch { thumbnailDirty = true }
    }

    // MARK: Edits (internal; each returns its own inverse)

    /// The primitive, invertible edits that commands translate into. Undo and redo replay
    /// these, looking entities up by ID and doing nothing if the target has gone (A §6.3).
    enum Edit: Sendable {
        case setText(page: PageID, box: BoxID, text: RichText?)
        case setPlacement(page: PageID, box: BoxID, placement: ImagePlacement?)
        case insertPage(Page, index: Int)
        case removePage(PageID)
        case setTypography(Typography)
        /// Replace `pageOrder` with a permutation of it.
        case setPageOrder([PageID])
        /// Replace an existing page wholesale (template change, done flag).
        case replacePage(Page)
        case setPageNumberStyle(PageNumberStyle)
        /// Several edits as one undo step, applied in order; the inverse is the reversed
        /// inverses. A sub-edit whose target has gone is skipped.
        case compound([Edit])
    }

    /// A command translated into its undoable edit, plus what it creates irreversibly
    /// (A §6.3): empty sessions for new image boxes, and bundled presets copied into the book.
    /// Both stay behind as harmless orphans if the edit is undone. A package can't drop a
    /// template file (`DirtySet` has no template deletions), so preset copy-in is deliberately
    /// outside the undo step.
    struct Prepared {
        var edit: Edit
        var sessions: [SessionID: Session] = [:]
        var templates: [TemplateID: Template] = [:]
    }

    /// Translates `command` without mutating anything. Nil if its target doesn't exist or it
    /// would change nothing.
    private func prepare(_ command: BookCommand) -> Prepared? {
        var created = Prepared(edit: .compound([]))
        var fixSplits = false
        let edit: Edit

        switch command {
        case let .setRichText(pageID, boxID, text, _):
            guard let page = content.pages[pageID], let template = content.template(for: page),
                  let box = template.box(boxID), case .text = box.content else { return nil }
            edit = .setText(page: pageID, box: boxID, text: text)

        case let .chooseVersion(pageID, boxID, versionID):
            guard let page = content.pages[pageID], let template = content.template(for: page),
                  let box = template.box(boxID), let slot = page.images[boxID],
                  content.sessions[slot.sessionID]?.version(versionID) != nil else { return nil }
            let placement = ImagePlacement(versionID: versionID, boxAspectWhenPlaced: content.boxAspect(box))
            edit = .setPlacement(page: pageID, box: boxID, placement: placement)

        case let .addPage(index, templateID, fix):
            guard let template = resolveTemplate(templateID, into: &created), template.kind.isStory else { return nil }
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
                  page.kind == .cover ? new.kind == .cover : new.kind.isStory else { return nil }
            let result = TemplateReassignment.reassign(page, from: old, to: new)
            var changed = result.page
            for boxID in result.unassignedImageBoxes {
                let session = Session(owner: .pageBox(pageID, boxID))
                created.sessions[session.id] = session
                changed.images[boxID] = ImageSlot(sessionID: session.id)
            }
            edit = .replacePage(changed)
            fixSplits = fix

        case let .importStoryText(texts, templateID, index, fix):
            guard !texts.isEmpty, let template = resolveTemplate(templateID, into: &created),
                  template.kind.isStory, let textBox = Self.firstTextBox(of: template) else { return nil }
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
            guard var page = content.pages[pageID], page.isDone != done else { return nil }
            page.isDone = done
            edit = .replacePage(page)

        case let .setTypography(typography):
            edit = .setTypography(typography)

        case let .setPageNumberStyle(style):
            guard style != content.style.pageNumbers else { return nil }
            edit = .setPageNumberStyle(style)

        case .addTemplate, .updateTemplate, .deleteTemplate:
            return nil // Phase 6 lane L1
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

    private func clamped(_ index: Int) -> Int { min(max(0, index), content.book.pageOrder.count) }

    /// A copy of `source` under a new ID: same template, text, checklist and placements, each
    /// image box's session copied under a new ID (versions keep their IDs, so placements still
    /// resolve; images are content-addressed, so no files are copied). Not done.
    private func duplicate(_ source: Page, sessions: inout [SessionID: Session]) -> Page {
        var page = source
        page.id = PageID()
        page.isDone = false
        for (boxID, slot) in source.images {
            var session = content.sessions[slot.sessionID] ?? Session(owner: .pageBox(page.id, boxID))
            session.id = SessionID()
            session.owner = .pageBox(page.id, boxID)
            // Requests still in flight deliver to the original session only.
            for i in session.messages.indices { session.messages[i].queueItemID = nil }
            sessions[session.id] = session
            page.images[boxID]?.sessionID = session.id
            if let placement = slot.placement, session.version(placement.versionID) == nil {
                page.images[boxID]?.placement = nil
            }
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

    /// The story order as the sequencer sees it.
    private static func sequence(of content: BookContent) -> [SequenceEntry] {
        content.book.pageOrder.map { id in
            let kind = content.pages[id].flatMap { content.template(for: $0) }?.kind
            return SequenceEntry(id: id, isSpread: kind == .spread)
        }
    }

    private static func merge(_ prepared: Prepared, into content: inout BookContent) {
        content.sessions.merge(prepared.sessions) { current, _ in current }
        content.templates.merge(prepared.templates) { current, _ in current }
    }

    /// Writes the irreversible parts of `prepared` (new sessions, copied-in presets).
    private func commitIrreversibleParts(of prepared: Prepared) {
        guard !prepared.sessions.isEmpty || !prepared.templates.isEmpty else { return }
        Self.merge(prepared, into: &content)
        scheduleSave(DirtySet(templates: Set(prepared.templates.keys), sessions: Set(prepared.sessions.keys)))
    }

    @discardableResult
    private func apply(_ edit: Edit, actionName: String) -> Bool {
        // Undo and redo replay through here too, so they can't write a read-only or closed book.
        guard isEditable, let (inverse, dirty) = applyEdit(edit) else { return false }
        content.book.modifiedAt = now()
        var allDirty = dirty
        allDirty.book = true
        scheduleSave(allDirty)
        refreshMissingFonts()
        if let undoManager {
            undoManager.registerUndo(withTarget: self) { doc in
                MainActor.assumeIsolated {
                    // Undo and redo end any typing step: the next keystroke is a new step.
                    doc.typing.close()
                    _ = doc.apply(inverse, actionName: actionName)
                }
            }
            undoManager.setActionName(actionName)
        }
        return true
    }

    private func applyEdit(_ edit: Edit) -> (Edit, DirtySet)? {
        Self.applyEdit(edit, to: &content)
    }

    /// Applies one edit to `content`, returning its inverse and what changed, or nil if the
    /// target no longer exists. Pure on `content`, so `wouldSplitSpread` can simulate.
    private static func applyEdit(_ edit: Edit, to content: inout BookContent) -> (Edit, DirtySet)? {
        switch edit {
        case let .setText(pageID, boxID, text):
            guard content.pages[pageID] != nil else { return nil }
            let old = content.pages[pageID]?.text[boxID]
            content.pages[pageID]?.text[boxID] = text
            return (.setText(page: pageID, box: boxID, text: old), DirtySet(pages: [pageID]))

        case let .setPlacement(pageID, boxID, placement):
            guard let slot = content.pages[pageID]?.images[boxID] else { return nil }
            // Never point at a version that was deleted (non-undoable) since.
            if let placement, content.sessions[slot.sessionID]?.version(placement.versionID) == nil { return nil }
            content.pages[pageID]?.images[boxID]?.placement = placement
            return (.setPlacement(page: pageID, box: boxID, placement: slot.placement), DirtySet(pages: [pageID]))

        case let .insertPage(page, index):
            guard content.pages[page.id] == nil, content.templates[page.templateID] != nil else { return nil }
            let at = min(max(0, index), content.book.pageOrder.count)
            content.pages[page.id] = page
            content.book.pageOrder.insert(page.id, at: at)
            return (.removePage(page.id), DirtySet(pages: [page.id]))

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

        case let .replacePage(page):
            guard let old = content.pages[page.id], content.templates[page.templateID] != nil else { return nil }
            content.pages[page.id] = page
            return (.replacePage(old), DirtySet(pages: [page.id]))

        case let .setPageNumberStyle(style):
            let old = content.style.pageNumbers
            content.style.pageNumbers = style
            return (.setPageNumberStyle(old), DirtySet(style: true))

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
}

private extension TemplateKind {
    /// Story pages use single or spread templates; the cover uses `.cover`.
    var isStory: Bool { self == .single || self == .spread }
}
