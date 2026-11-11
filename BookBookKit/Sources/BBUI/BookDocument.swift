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
    /// Phase 10: where each asset is used (A §4.4), refreshed incrementally with every change
    /// (`scheduleSave` sees every edit, delivery and undo). Read through `usageSites(of:)`.
    public private(set) var usageIndex: UsageIndex

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
    /// Open undo groups (`beginUndoGroup`): nesting depth and the inverses collected so far.
    @ObservationIgnored private var groupDepth = 0
    /// The open group's undo entry. It is registered at the group's first edit (not at its end),
    /// so an undo that arrives while the group is still open undoes the group first.
    @ObservationIgnored private var openGroup: UndoGroupRecord?
    /// Counts undo registrations, so `endUndoGroup` can tell whether the group's step is
    /// still the newest one before renaming it.
    @ObservationIgnored private var undoRegistrations = 0
    /// Observes `fontsRegisteredNotification`, so a font imported in another open book refreshes this one.
    @ObservationIgnored private nonisolated(unsafe) var fontsObserver: (any NSObjectProtocol)?

    /// Posted (process-wide) after a font import registers a font, so every open book drops stale
    /// fallback layouts and recomputes its missing-font banner (A §8.3).
    public static let fontsRegisteredNotification = Notification.Name("app.bookbook.fontsRegistered")

    private final class UndoGroupRecord {
        var inverses: [Edit] = []
        /// The step's name: from `beginUndoGroup`, else the first edit's command, and finally
        /// `endUndoGroup`'s (redo uses the final one).
        var actionName: String?
        /// The name the step was registered with.
        var registeredName: String?
        /// `undoRegistrations` right after the group's step was registered (nil until then).
        var registeredAt: Int?
        /// Called if an undo or redo closes the group before `endUndoGroup` does.
        let onClosedByReplay: (@MainActor () -> Void)?
        init(actionName: String?, onClosedByReplay: (@MainActor () -> Void)?) {
            self.actionName = actionName
            self.onClosedByReplay = onClosedByReplay
        }
    }

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
        self.usageIndex = UsageIndex(content: content)
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
        fontsObserver = NotificationCenter.default.addObserver(
            forName: Self.fontsRegisteredNotification, object: nil, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isClosed else { return }
                self.fontsRevision += 1
                self.refreshMissingFonts()
            }
        }
    }

    isolated deinit {
        if let fontsObserver { NotificationCenter.default.removeObserver(fontsObserver) }
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
        NotificationCenter.default.post(name: Self.fontsRegisteredNotification, object: nil)
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

    /// Adds the run fonts of `text` that don't resolve to `missingFonts` (a coalesced keystroke
    /// or paste). Cheap on plain typing: no run overrides means no CoreText lookups. The body
    /// and title fonts were checked by the `refreshMissingFonts` that opened the typing step.
    private func noteMissingRunFonts(in text: RichText) {
        var names: Set<String> = []
        for paragraph in text.paragraphs {
            for run in paragraph.runs where !run.text.isEmpty {
                if let name = run.fontFamily, !missingFonts.contains(name) { names.insert(name) }
            }
        }
        guard !names.isEmpty else { return }
        let found = names.filter { !FontAvailability.isAvailable(postScriptName: $0) }
        guard !found.isEmpty else { return }
        missingFonts = Set(missingFonts).union(found).sorted()
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
        if groupDepth > 0 {
            // Inside an undo group: apply and save, but collect the inverse for `endUndoGroup`.
            guard let inverse = applyAndSave(edit) else { return false }
            if let record = openGroup {
                record.inverses.append(inverse)
                if record.registeredAt == nil { registerGroupUndo(record, fallbackName: command.actionName) }
            }
            return true
        }
        // A typing edit that joins the open step changes the content but registers nothing: the
        // step's undo entry still restores the text from before the step began (A §6.3).
        let sameManager = typingUndoManager != nil && typingUndoManager === undoManager
        if typing.shouldCoalesce(command), sameManager, let (_, dirty) = applyEdit(edit) {
            didApply(dirty)
            // Only the edited box can bring in a missing font (a paste), so check just that.
            if case let .setText(page, box, _) = edit, let text = content.pages[page]?.text[box] {
                noteMissingRunFonts(in: text)
            }
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
    /// Closes any open typing step. Nested calls are ignored (the outer group wins, and so does
    /// its `onClosedByReplay`).
    ///
    /// `actionName` names the step when it registers (at the first edit); without it the first
    /// edit's command names it. A nested call can still supply the name while the outer group
    /// has none and hasn't registered yet.
    ///
    /// `onClosedByReplay` is called if an undo or redo closes the group before
    /// `endUndoGroup` does; the caller holding the group (a drag, a pending continuous edit)
    /// then drops its state. The handler belongs to this group only, so several editors on
    /// one document can't overwrite each other's.
    public func beginUndoGroup(actionName: String? = nil, onClosedByReplay: (@MainActor () -> Void)? = nil) {
        typing.close()
        if groupDepth == 0 {
            openGroup = UndoGroupRecord(actionName: actionName, onClosedByReplay: onClosedByReplay)
        } else if let actionName, let record = openGroup, record.registeredAt == nil, record.actionName == nil {
            record.actionName = actionName
        }
        groupDepth += 1
    }

    /// Closes the open group (mouse-up) and registers one undo step named `actionName` that
    /// restores everything from before `beginUndoGroup()`. Registers nothing if no edit was
    /// performed in the group. No-op without an open group.
    public func endUndoGroup(actionName: String) {
        guard groupDepth > 0 else { return }
        groupDepth -= 1
        guard groupDepth == 0, let record = openGroup else { return }
        openGroup = nil
        record.actionName = actionName
        // The step was named when it registered, so usually there is nothing to do. Rename it
        // only if the name changed, the step is still the newest one (nothing of ours registered
        // since, and the top step still carries its name, which catches registrations from
        // outside the document), and an NSUndoManager group is open: `setActionName` with none
        // open (a timer closing a continuous edit, a mouse-up that registered nothing) would
        // start a new, empty group that shows up as an extra undo step.
        if let registeredAt = record.registeredAt, let registeredName = record.registeredName,
           registeredName != actionName, registeredAt == undoRegistrations,
           let undoManager, undoManager.groupingLevel > 0, !undoManager.isUndoing, !undoManager.isRedoing,
           undoManager.canUndo, undoManager.undoActionName == registeredName {
            undoManager.setActionName(actionName)
        }
    }

    /// Registers the group's single undo step. Its inverses are read when it fires, so edits
    /// made after registration are included. Undoing a still-open group closes it first.
    private func registerGroupUndo(_ record: UndoGroupRecord, fallbackName: String) {
        guard let undoManager else { return }
        let name = record.actionName ?? fallbackName
        record.actionName = name
        record.registeredName = name
        undoManager.registerUndo(withTarget: self) { doc in
            MainActor.assumeIsolated {
                doc.typing.close()
                if doc.openGroup === record {
                    doc.openGroup = nil
                    doc.groupDepth = 0
                    record.onClosedByReplay?()
                }
                // Replay newest first, so everything returns to the state at begin.
                _ = doc.apply(.compound(record.inverses.reversed()), actionName: record.actionName ?? name)
            }
        }
        undoManager.setActionName(name)
        undoRegistrations += 1
        record.registeredAt = undoRegistrations
    }

    /// For non-undoable writes (A §6.3): AI results, session changes, renaming the book. Never
    /// registers undo. `body` returns what it changed. Does nothing if read-only or closed.
    /// Returns true if `body` changed something (false when read-only or closed).
    @discardableResult
    public func performIrreversible(_ body: (inout BookContent) -> DirtySet) -> Bool {
        guard isEditable else { return false }
        let dirty = body(&content)
        guard !dirty.isEmpty else { return false }
        didApply(dirty)
        return true
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

    /// Book Settings (PD §8.12): set the author. Not undoable, like `rename(to:)`; the cover
    /// redraws from `content.book`. Returns false for a read-only book.
    @discardableResult
    public func setAuthor(_ author: String) -> Bool {
        setBookField(\.author, to: author.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Phase 9: the optional per-book budget (PD §5, §8.12). Not undoable, like the author.
    /// Negative values are refused; nil clears it.
    @discardableResult
    public func setBudget(_ budget: Decimal?) -> Bool {
        guard (budget ?? 0) >= 0 else { return false }
        return setBookField(\.budget, to: budget)
    }

    /// Renames the book (`Book.title`; the package folder keeps its name). Not undoable
    /// (PD §8.10). Returns false if the title is empty or the book can't be edited.
    @discardableResult
    public func rename(to title: String) -> Bool {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return false }
        return setBookField(\.title, to: title)
    }

    /// Sets one `Book` field irreversibly (saving only if it changed). False if the book can't
    /// be edited; true otherwise, changed or not.
    private func setBookField<Value: Equatable>(_ field: WritableKeyPath<Book, Value>, to value: Value) -> Bool {
        guard isEditable else { return false }
        performIrreversible { content in
            guard content.book[keyPath: field] != value else { return DirtySet() }
            content.book[keyPath: field] = value
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
        refreshUsage(dirty)
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

    /// Re-derives the usage entries for what `dirty` touched (deleted pages drop out).
    private func refreshUsage(_ dirty: DirtySet) {
        let pages = dirty.pages.union(dirty.deletedPages)
        guard !pages.isEmpty || !dirty.sessions.isEmpty else { return }
        var index = usageIndex
        index.refresh(content, pages: pages, sessions: dirty.sessions)
        if index != usageIndex { usageIndex = index }
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
        /// `baseline` non-nil also replaces the slot's `acknowledged` (placing a new version
        /// clears its `boxAspect`; the inverse restores the old baseline).
        case setPlacement(page: PageID, box: BoxID, placement: ImagePlacement?, baseline: FlagBaseline? = nil)
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
    private func prepare(_ command: BookCommand) -> Prepared? {
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
                let (session, slot) = Self.emptySlot(page: pageID, box: boxID)
                created.sessions[session.id] = session
                changed.images[boxID] = slot
            }
            edit = .setPageLayout(changed)
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

    /// The story order as the sequencer sees it: one entry per `pageOrder` ID. Unlike
    /// `PageSequencer.entries(for:)`, an ID whose page is missing still gets an entry (as a
    /// single page), so `blankInsertions` indices stay indices into `pageOrder`.
    private static func sequence(of content: BookContent) -> [SequenceEntry] {
        content.book.pageOrder.map { id in
            let kind = content.pages[id].flatMap { content.template(for: $0) }?.kind
            return SequenceEntry(id: id, isSpread: kind == .spread)
        }
    }

    private static func merge(_ prepared: Prepared, into content: inout BookContent) {
        content.sessions.merge(prepared.sessions) { current, _ in current }
        content.templates.merge(prepared.templates) { current, _ in current }
        for (pageID, slots) in prepared.slots {
            for (boxID, slot) in slots where content.pages[pageID]?.images[boxID] == nil {
                content.pages[pageID]?.images[boxID] = slot
            }
        }
    }

    /// Writes the irreversible parts of `prepared` (new sessions, copied-in presets).
    private func commitIrreversibleParts(of prepared: Prepared) {
        guard !prepared.sessions.isEmpty || !prepared.templates.isEmpty || !prepared.slots.isEmpty else { return }
        Self.merge(prepared, into: &content)
        scheduleSave(DirtySet(templates: Set(prepared.templates.keys), pages: Set(prepared.slots.keys),
                              sessions: Set(prepared.sessions.keys)))
    }

    @discardableResult
    private func apply(_ edit: Edit, actionName: String) -> Bool {
        // Undo and redo replay through here too, so they can't write a read-only or closed book.
        guard isEditable, let inverse = applyAndSave(edit) else { return false }
        registerUndo(inverse, actionName: actionName)
        return true
    }

    /// Applies `edit`, schedules the save and returns the inverse. Registers nothing.
    private func applyAndSave(_ edit: Edit) -> Edit? {
        guard isEditable, let (inverse, dirty) = applyEdit(edit) else { return nil }
        didApply(dirty)
        // Only text (pages, including deleted and restored ones) and the style's typography name fonts.
        if dirty.style || !dirty.pages.isEmpty || !dirty.deletedPages.isEmpty { refreshMissingFonts() }
        return inverse
    }

    /// After any applied edit (registered or a coalesced keystroke): stamps `modifiedAt` and
    /// schedules the save of what changed plus the book.
    private func didApply(_ dirty: DirtySet) {
        content.book.modifiedAt = now()
        var allDirty = dirty
        allDirty.book = true
        scheduleSave(allDirty)
    }

    /// Registers `inverse` as one undo step; replaying it registers the redo.
    private func registerUndo(_ inverse: Edit, actionName: String) {
        if let undoManager {
            undoManager.registerUndo(withTarget: self) { doc in
                MainActor.assumeIsolated {
                    // Undo and redo end any typing step: the next keystroke is a new step.
                    doc.typing.close()
                    _ = doc.apply(inverse, actionName: actionName)
                }
            }
            undoManager.setActionName(actionName)
            undoRegistrations += 1
        }
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

        case let .setPlacement(pageID, boxID, placement, baseline):
            guard let slot = content.pages[pageID]?.images[boxID] else { return nil }
            // Never point at a version that was deleted (non-undoable) since.
            if let placement, content.sessions[slot.sessionID]?.version(placement.versionID) == nil { return nil }
            content.pages[pageID]?.images[boxID]?.placement = placement
            if let baseline { content.pages[pageID]?.images[boxID]?.acknowledged = baseline }
            return (.setPlacement(page: pageID, box: boxID, placement: slot.placement,
                                  baseline: baseline == nil ? nil : slot.acknowledged),
                    DirtySet(pages: [pageID]))

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
            content.pages[page.id] = page
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
            content.pages[page.id] = page
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
            content.assets[asset.id] = asset
            return (.removeAsset(asset.id), DirtySet(assets: [asset.id]))

        case let .removeAsset(id):
            guard let old = content.assets[id] else { return nil }
            content.assets[id] = nil
            return (.insertAsset(old), DirtySet(deletedAssets: [id]))

        case let .updateAsset(from, to):
            guard let current = content.assets[to.id] else { return nil }
            let merged = mergeAsset(current: current, from: from, to: to)
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
    /// goes down.
    static func mergeAsset(current: Asset, from: Asset, to: Asset) -> Asset {
        var out = current
        if to.name != from.name { out.name = to.name }
        if to.description != from.description { out.description = to.description }
        if to.chosen != from.chosen { out.chosen = to.chosen }
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
    private static func emptySlot(page: PageID, box: BoxID) -> (session: Session, slot: ImageSlot) {
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

private extension TemplateKind {
    /// Story pages use single or spread templates; the cover uses `.cover`.
    var isStory: Bool { self == .single || self == .spread }
}
