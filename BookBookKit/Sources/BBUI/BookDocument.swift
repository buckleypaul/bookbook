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
    /// Image files (`<sha256>.<ext>`) that an inverse edit carries (style references, asset
    /// reference photos), so undo or redo could bring them back. Clean up keeps these files
    /// even when nothing in `content` uses them (the open-time sweep removes them later).
    /// Only grows: a superset of what the undo and redo stacks hold.
    @ObservationIgnored private(set) var undoImageFileNames: Set<String> = []
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
            for await error in results { self?.noteSaveResult(error) }
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
        var content: BookContent
        do {
            content = try await store.load()
        } catch {
            await store.releaseLock()
            throw error
        }
        // Load-time data repair, not an edit (never in undo): style references saved before they
        // were normalized (HEIC, mislabelled bytes) become PNG/JPEG. Never blocks the open.
        if !readOnly, let repaired = await store.repairingStyleReferences(in: content) {
            content = repaired
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
            noteSaveResult(nil)
        } catch {
            noteSaveResult(error)
        }
        await writeThumbnailIfNeeded()
    }

    /// Records a save's result in `lastSaveError`. Written only when it changes: the usual
    /// nil-to-nil after an autosave would otherwise invalidate every view reading the document.
    private func noteSaveResult(_ error: StoreError?) {
        if lastSaveError != error { lastSaveError = error }
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

    /// Whether a change could alter the library thumbnail, so typing on other pages doesn't
    /// redraw it. `dirty` is what the change itself touched (before `didApply` adds `book`).
    /// Conservative: book-level data (title, author, page order, cover), the style, any page
    /// deletion (the first story page may change), or the drawn page, its template or one of
    /// its sessions.
    private func affectsThumbnail(_ dirty: DirtySet) -> Bool {
        if dirty.book || dirty.style || !dirty.deletedPages.isEmpty { return true }
        guard let page = BookThumbnail.page(in: content) else { return false }
        return dirty.pages.contains(page.id) || dirty.templates.contains(page.templateID)
            || page.images.values.contains { dirty.sessions.contains($0.sessionID) }
    }

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

    // MARK: Applying edits

    /// Writes the irreversible parts of `prepared` (new sessions, copied-in presets).
    private func commitIrreversibleParts(of prepared: Prepared) {
        guard !prepared.sessions.isEmpty || !prepared.templates.isEmpty || !prepared.slots.isEmpty else { return }
        Self.merge(prepared, into: &content)
        let dirty = DirtySet(templates: Set(prepared.templates.keys), pages: Set(prepared.slots.keys),
                             sessions: Set(prepared.sessions.keys))
        scheduleSave(dirty)
        if affectsThumbnail(dirty) { markThumbnailDirty() }
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
        if affectsThumbnail(dirty) { markThumbnailDirty() }
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
        guard let result = Self.applyEdit(edit, to: &content) else { return nil }
        undoImageFileNames.formUnion(Self.imageFileNames(in: result.0))
        return result
    }
}
