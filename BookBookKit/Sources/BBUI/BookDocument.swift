import BBModel
import BBStore
import Foundation
import Observation

/// One open book (A §6.1, §6.3). Holds the in-memory value tree, its `BookStore`, and the
/// command layer. Every undoable edit goes through `perform(_:)`; AI results and other
/// non-undoable writes go through `performIrreversible(_:)`.
///
/// HOT SPOT (plan §2.5): only the main thread edits this file.
@MainActor @Observable
public final class BookDocument {
    public let id: BookID
    public private(set) var content: BookContent
    /// The last autosave failure, shown by the window. Cleared by the next successful flush.
    public private(set) var lastSaveError: StoreError?

    @ObservationIgnored public let store: BookStore
    /// The window's undo manager (SwiftUI `@Environment(\.undoManager)`), set by the window.
    @ObservationIgnored public weak var undoManager: UndoManager?
    @ObservationIgnored private var saveChain: Task<Void, Never>?
    @ObservationIgnored private var autosaveResults: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let now: () -> Date

    public init(content: BookContent, store: BookStore, now: @escaping () -> Date = { Date() }) {
        self.id = content.book.id
        self.content = content
        self.store = store
        self.now = now
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
    }

    isolated deinit {
        autosaveResults?.cancel()
    }

    /// Loads the package at `url` (rolling the journal forward first).
    public static func open(at url: URL) async throws(StoreError) -> BookDocument {
        let store = BookStore(packageURL: url)
        let content = try await store.load()
        return BookDocument(content: content, store: store)
    }

    // MARK: Undoable edits

    /// Applies an undoable command and registers its inverse. Returns false (and registers
    /// nothing) if the command's target doesn't exist.
    @discardableResult
    public func perform(_ command: BookCommand) -> Bool {
        guard let edit = makeEdit(for: command) else { return false }
        return apply(edit, actionName: command.actionName)
    }

    /// For non-undoable writes (A §6.3): AI results, session changes. Never registers undo.
    /// `body` returns what it changed.
    public func performIrreversible(_ body: (inout BookContent) -> DirtySet) {
        var dirty = body(&content)
        guard !dirty.isEmpty else { return }
        content.book.modifiedAt = now()
        dirty.book = true
        scheduleSave(dirty)
    }

    // MARK: Saving

    /// Writes any pending autosave now (window close, quit, hide).
    public func flush() async {
        let pending = saveChain
        await pending?.value
        do {
            try await store.flush()
            lastSaveError = nil
        } catch {
            lastSaveError = error
        }
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
    }

    // MARK: Edits (internal; each returns its own inverse)

    /// The primitive, invertible edits that commands translate into. Undo and redo replay
    /// these, looking entities up by ID and doing nothing if the target has gone (A §6.3).
    enum Edit: Sendable {
        case setText(page: PageID, box: BoxID, text: RichText?)
        case setPlacement(page: PageID, box: BoxID, placement: ImagePlacement?)
        case insertPage(Page, index: Int)
        case removePage(PageID)
    }

    private func makeEdit(for command: BookCommand) -> Edit? {
        switch command {
        case let .setRichText(pageID, boxID, text):
            guard let page = content.pages[pageID], let template = content.template(for: page),
                  let box = template.box(boxID), case .text = box.content else { return nil }
            return .setText(page: pageID, box: boxID, text: text)

        case let .chooseVersion(pageID, boxID, versionID):
            guard let page = content.pages[pageID], let template = content.template(for: page),
                  let box = template.box(boxID), let slot = page.images[boxID],
                  content.sessions[slot.sessionID]?.version(versionID) != nil else { return nil }
            let placement = ImagePlacement(versionID: versionID, boxAspectWhenPlaced: content.boxAspect(box))
            return .setPlacement(page: pageID, box: boxID, placement: placement)

        case let .addPage(index, templateID):
            guard let template = content.templates[templateID], template.kind == .single else { return nil }
            // The new page's empty sessions are created irreversibly (they're harmless if the
            // add is undone); the page itself is the undoable part.
            var sessions: [SessionID: Session] = [:]
            let page = BookContent.makePage(kind: .story, template: template, sessions: &sessions)
            content.sessions.merge(sessions) { current, _ in current }
            scheduleSave(DirtySet(sessions: Set(sessions.keys)))
            return .insertPage(page, index: index)

        case let .deletePage(pageID):
            guard content.book.pageOrder.contains(pageID) else { return nil }
            return .removePage(pageID)
        }
    }

    @discardableResult
    private func apply(_ edit: Edit, actionName: String) -> Bool {
        guard let (inverse, dirty) = applyEdit(edit) else { return false }
        content.book.modifiedAt = now()
        var allDirty = dirty
        allDirty.book = true
        scheduleSave(allDirty)
        if let undoManager {
            undoManager.registerUndo(withTarget: self) { doc in
                MainActor.assumeIsolated { _ = doc.apply(inverse, actionName: actionName) }
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
        }
    }
}
