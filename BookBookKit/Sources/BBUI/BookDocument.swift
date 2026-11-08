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
        guard isEditable, let edit = makeEdit(for: command) else {
            typing.close()
            return false
        }
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
    public func wouldSplitSpread(_ command: BookCommand) -> Bool {
        fatalError("Phase 5 lane L3")
    }

    /// Book Settings (PD §8.12): set the author. Not undoable, like `rename(to:)`; the cover
    /// redraws from `content.book`. Returns false for a read-only book.
    @discardableResult
    public func setAuthor(_ author: String) -> Bool {
        fatalError("Phase 5 lane L3")
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
    }

    private func makeEdit(for command: BookCommand) -> Edit? {
        switch command {
        case let .setRichText(pageID, boxID, text, _):
            guard let page = content.pages[pageID], let template = content.template(for: page),
                  let box = template.box(boxID), case .text = box.content else { return nil }
            return .setText(page: pageID, box: boxID, text: text)

        case let .chooseVersion(pageID, boxID, versionID):
            guard let page = content.pages[pageID], let template = content.template(for: page),
                  let box = template.box(boxID), let slot = page.images[boxID],
                  content.sessions[slot.sessionID]?.version(versionID) != nil else { return nil }
            let placement = ImagePlacement(versionID: versionID, boxAspectWhenPlaced: content.boxAspect(box))
            return .setPlacement(page: pageID, box: boxID, placement: placement)

        case let .addPage(index, templateID, _):
            guard let template = content.templates[templateID], template.kind == .single else { return nil }
            // The new page's empty sessions are created irreversibly (they're harmless if the
            // add is undone); the page itself is the undoable part.
            var sessions: [SessionID: Session] = [:]
            let page = BookContent.makePage(kind: .story, template: template, sessions: &sessions)
            content.sessions.merge(sessions) { current, _ in current }
            scheduleSave(DirtySet(sessions: Set(sessions.keys)))
            return .insertPage(page, index: index)

        case let .deletePage(pageID, _):
            guard content.book.pageOrder.contains(pageID) else { return nil }
            return .removePage(pageID)

        case let .setTypography(typography):
            return .setTypography(typography)

        case .duplicatePage, .reorderPages, .setPageTemplate, .importStoryText, .setPageDone,
             .setPageNumberStyle:
            fatalError("Phase 5 lane L3")
        }
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

    /// Applies one edit to `content`, returning its inverse and what changed, or nil if the
    /// target no longer exists.
    private func applyEdit(_ edit: Edit) -> (Edit, DirtySet)? {
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
        }
    }
}
