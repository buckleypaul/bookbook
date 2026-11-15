import BBModel
import BBStore
import SwiftUI

/// A book window (A §6.1, §6.2). Opens the `BookDocument` through `AppModel` (taking the book's
/// lock, or offering read-only if another BookBook holds it) and closes it (flush, release the
/// lock) when the window closes. The first window to appear also reopens the books that were
/// open at quit.
public struct BookWindow: View {
    private let bookID: BookID
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @State private var document: BookDocument?
    @State private var loadError: String?
    @State private var lockOwner: LockOwner?
    @State private var confirmTakeOver = false

    public init(bookID: BookID) {
        self.bookID = bookID
    }

    /// The window's minimum width: both panel cards at their minimums, the detail card's minimum
    /// and the desk gaps (`EditorPanelMetrics`: 160 + 260 + 320 + 4 × 10 = 780 pt), with room
    /// to spare. `BookEditorLayoutTests` checks the editor settles at this width.
    static let minimumWidth: CGFloat = 840

    public var body: some View {
        Group {
            if let document {
                BookEditor(document: document)
            } else if let loadError {
                CrayonEmptyState("Couldn't Open the Book", systemImage: "exclamationmark.triangle",
                                 color: Crayon.tomato, message: loadError) {
                    Button("Try Again") { Task { await retry() } }
                        .buttonStyle(.crayon)
                    closeButton
                }
            } else if let lockOwner {
                let offersOpenAnyway = LockTakeOver.offersOpenAnyway(lockOwner)
                CrayonEmptyState("Book in Use", systemImage: "lock", color: Crayon.grape,
                                 message: LockTakeOver.message(for: lockOwner, offersOpenAnyway: offersOpenAnyway)) {
                    Button("Open Read-Only") { Task { await load(readOnly: true) } }
                        .buttonStyle(.crayon)
                    if offersOpenAnyway {
                        Button("Open Anyway…") { confirmTakeOver = true }
                            .buttonStyle(.crayon(Crayon.sky))
                    }
                    closeButton
                }
            } else {
                VStack(spacing: 18) {
                    CrayonBlobIcon(systemImage: "book.fill", color: Crayon.sky, size: 64)
                    ProgressView("Opening…")
                        .font(Crayon.font(.headline, weight: .bold))
                        .foregroundStyle(Crayon.inkSoft)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: Self.minimumWidth, minHeight: 520)
        .task(id: bookID) { await load(readOnly: false) }
        .task { await app.reopenBooks { openWindow(value: $0) } }
        .alert("Open this book anyway?", isPresented: $confirmTakeOver) {
            Button("Open Anyway", role: .destructive) { Task { await openAnyway() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(LockTakeOver.warning)
        }
        .onChange(of: app.windowCloseRequests.contains(bookID)) { _, requested in
            guard requested else { return }
            app.windowDidClose(bookID)
            dismiss()
        }
        .onDisappear {
            let app = app, bookID = bookID
            Task { await app.closeBook(bookID) }
        }
    }

    /// Closes the window (the book couldn't be opened, or the user won't open a locked one).
    private var closeButton: some View {
        Button("Close") { dismiss() }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
    }

    /// "Try Again" after a failed open: back to the opening state, then a fresh editable open.
    private func retry() async {
        loadError = nil
        lockOwner = nil
        await load(readOnly: false)
    }

    /// "Open Anyway" (#99b): takes the lock over from `lockOwner`, then opens the book editable.
    private func openAnyway() async {
        guard let owner = lockOwner, let url = app.entry(for: bookID)?.url else {
            await load(readOnly: false)
            return
        }
        let store = BookStore(packageURL: url)
        switch await LockTakeOver.takeOver(store, from: owner) {
        case .taken:
            // The store's hold is counted per process, so the real open finds the lock ours.
            await load(readOnly: false)
            await store.releaseLock()
        case let .changed(newOwner):
            // The lock changed hands while the warning was up: the locked screen now names the
            // new holder, so the user decides again.
            lockOwner = newOwner
        case let .failed(message):
            lockOwner = nil
            loadError = message
        }
    }

    private func load(readOnly: Bool) async {
        do {
            document = try await app.openBook(bookID, readOnly: readOnly)
            lockOwner = nil
        } catch StoreError.locked(let owner) {
            lockOwner = owner
        } catch {
            // A book that left the library while BookBook was closed (a window SwiftUI restored):
            // close quietly (A §6.1, PD §8.1).
            if case StoreError.notFound = error, !(await app.resolves(bookID)) {
                app.forgetBook(bookID)
                dismiss()
                return
            }
            loadError = StoreErrorText.message(for: error)
        }
    }
}

/// "Open Anyway" for a book whose lock another process holds (#99b). Offered for locks from
/// another Mac (which can't be proved stale from here); a live lock on this Mac keeps the
/// read-only choice only.
enum LockTakeOver {
    enum Outcome: Equatable {
        case taken
        case changed(LockOwner)
        case failed(String)
    }

    static let warning = "If another Mac is still editing this book, its changes and yours can overwrite each other and work can be lost. Only continue if you know the other copy of BookBook is closed, for example after a crash."

    /// The locked screen's message: who holds the book (named once), then what can be done.
    static func message(for owner: LockOwner, offersOpenAnyway: Bool) -> String {
        let advice = offersOpenAnyway
            ? "You can open it read-only to look at it. If BookBook on that Mac has quit or crashed, you can open it anyway."
            : "You can open it read-only to look at it, but you won't be able to change it."
        return "\(StoreErrorText.message(for: .locked(owner))) \(advice)"
    }

    /// Whether the locked screen offers "Open Anyway": the lock names a different Mac than
    /// `thisMachine` (by host UUID when both sides have one, else by host name). Tests pass a
    /// stand-in for this Mac.
    static func offersOpenAnyway(_ owner: LockOwner?, thisMachine: LockOwner = .current) -> Bool {
        guard let owner else { return false }
        return !owner.isOnSameMachine(as: thisMachine)
    }

    /// Takes `.lock` over from `owner` with `store`; the caller releases the store's hold once
    /// the book has opened.
    static func takeOver(_ store: BookStore, from owner: LockOwner) async -> Outcome {
        do {
            switch try await store.takeOverLock(expectedOwner: owner) {
            case .acquired: return .taken
            case let .heldByOther(newOwner): return .changed(newOwner)
            }
        } catch {
            return .failed(StoreErrorText.message(for: error))
        }
    }
}
