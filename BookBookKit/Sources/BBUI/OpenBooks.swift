import BBAI
import BBAICore
import BBModel
import BBStore
import Foundation
import Observation
import os

/// The registry of open books, `BookID → BookDocument` (A §6.1), the library's `BookID → URL`
/// lookup (fed by `LibraryIndex`), and the ordered list of open books that BookBook reopens at
/// relaunch (`openBookIDs` in `UserDefaults`, IDs only).
///
/// It is also the one place queue results are written (A §6.4). Per book, opening, closing and
/// delivering run one at a time, so:
/// - `open` waits for a delivery that is writing to the closed book on disk;
/// - a delivery that arrives while the book is closing waits for the close, then writes to disk;
/// - a delivery to an open book is applied before any later close flushes it.
@MainActor @Observable
public final class OpenBooks {
    /// `UserDefaults` key for the ordered open-book list (A §6.1).
    public static let openBookIDsKey = "openBookIDs"

    public private(set) var documents: [BookID: BookDocument] = [:]
    /// Books with an open window, in the order they opened. Saved to `defaults` on every change.
    public private(set) var openBookIDs: [BookID]
    /// Set while the app quits (from `applicationShouldTerminate`): closing windows then keeps
    /// their entries, so the books reopen at relaunch.
    public var isTerminating = false
    @ObservationIgnored private var closing: Set<BookID> = []
    @ObservationIgnored private var tails: [BookID: Task<Void, Never>] = [:]
    @ObservationIgnored private var urls: [BookID: URL] = [:]
    @ObservationIgnored private let defaults: UserDefaults
    /// Resolves a book that isn't in the URL map, or whose package has gone. `AppModel` points it
    /// at `LibraryIndex`; the default rescans `library`.
    @ObservationIgnored public var resolveURL: @MainActor (BookID) async -> URL?
    /// Called when a finished picture couldn't be written into its book.
    @ObservationIgnored public var onDeliveryProblem: (MessageID, String) -> Void = { _, _ in }
    /// Called when a delivery was written (clears an earlier problem reported for the message).
    @ObservationIgnored public var onDelivered: (MessageID) -> Void = { _ in }

    private static let log = Logger(subsystem: "app.bookbook", category: "OpenBooks")

    /// - Parameter defaults: where `openBookIDs` is kept (tests pass a suite).
    public init(library: Library, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.openBookIDs = Self.readList(defaults)
        self.resolveURL = { id in
            await Task.detached { library.scan() }.value.first { $0.id == id }?.url
        }
    }

    public func document(for id: BookID) -> BookDocument? { documents[id] }

    /// Records where books live (from the library index or a scan).
    public func remember(_ entries: [LibraryEntry]) {
        for entry in entries { urls[entry.id] = entry.url }
    }

    /// The package URL for a book. A remembered URL whose package has gone (trashed, moved) is
    /// resolved again.
    public func packageURL(for id: BookID) async -> URL? {
        if let url = urls[id], FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) { return url }
        let url = await resolveURL(id)
        urls[id] = url
        return url
    }

    // MARK: Open-books list (A §6.1)

    /// The saved list in order, keeping only the books `resolves` still finds. The rest are
    /// dropped from the saved list silently. Called once at launch, after the index is loaded.
    public func booksToReopen(resolves: (BookID) -> Bool) -> [BookID] {
        let kept = openBookIDs.filter(resolves)
        if kept != openBookIDs { setList(kept) }
        return kept
    }

    /// Removes a book from the list without closing anything (its window found no book).
    public func forget(_ id: BookID) {
        guard !isTerminating, openBookIDs.contains(id) else { return }
        setList(openBookIDs.filter { $0 != id })
    }

    private func noteOpened(_ id: BookID) {
        guard !openBookIDs.contains(id) else { return }
        setList(openBookIDs + [id])
    }

    private func setList(_ ids: [BookID]) {
        openBookIDs = ids
        defaults.set(ids.map(\.rawValue.uuidString), forKey: Self.openBookIDsKey)
    }

    private static func readList(_ defaults: UserDefaults) -> [BookID] {
        var seen: Set<BookID> = []
        return (defaults.stringArray(forKey: openBookIDsKey) ?? []).compactMap { string in
            guard let uuid = UUID(uuidString: string) else { return nil }
            let id = BookID(rawValue: uuid)
            return seen.insert(id).inserted ? id : nil
        }
    }

    // MARK: Per-book serialization

    /// Runs `operation` after every earlier operation on the same book has finished.
    private func serialized<T: Sendable>(_ id: BookID, _ operation: @escaping @MainActor () async -> T) async -> T {
        let previous = tails[id]
        let task = Task { @MainActor in
            await previous?.value
            return await operation()
        }
        let tail = Task<Void, Never> { _ = await task.value }
        tails[id] = tail
        let result = await task.value
        if tails[id] == tail { tails[id] = nil }
        return result
    }

    // MARK: Open and close

    /// Opens a book, or returns it if it's already open, and adds it to the open-books list.
    /// Takes the book's lock first: if another process holds it, throws `StoreError.locked`,
    /// unless `readOnly` is set (then it opens read-only).
    public func open(_ id: BookID, readOnly: Bool = false) async throws -> BookDocument {
        if let document = documents[id], !closing.contains(id) {
            noteOpened(id)
            return document
        }
        let result: Result<BookDocument, any Error> = await serialized(id) { [self] in
            if let document = documents[id] { return .success(document) }
            guard let url = await packageURL(for: id) else { return .failure(StoreError.notFound("book \(id)")) }
            do {
                let document = try await BookDocument.open(at: url, readOnly: readOnly)
                documents[id] = document
                return .success(document)
            } catch {
                return .failure(error)
            }
        }
        let document = try result.get()
        noteOpened(id)
        return document
    }

    /// Flushes, releases the lock and forgets a book (its window closed). Deliveries arriving
    /// meanwhile wait, then go to the package on disk. Removes the book from the open-books list
    /// unless the app is quitting.
    public func close(_ id: BookID) async {
        if !isTerminating, openBookIDs.contains(id) { setList(openBookIDs.filter { $0 != id }) }
        guard documents[id] != nil else { return }
        closing.insert(id)
        await serialized(id) { [self] in
            if let document = documents[id] {
                await document.close()
                documents[id] = nil
            }
            closing.remove(id)
        }
    }

    /// Sets a book's title, one at a time with its other operations: through its document if it's
    /// open (flushed), otherwise through `Library.rename` (headless store under the lock), so a
    /// delivery or snapshot of the same closed book can't run alongside it.
    public func rename(_ entry: LibraryEntry, to title: String, in library: Library, now: Date) async throws {
        let result: Result<Void, any Error> = await serialized(entry.id) { [self] in
            if let document = documents[entry.id], !document.isClosed {
                guard document.rename(to: title) else { return .failure(StoreError.readOnly) }
                await document.flush()
                return .success(())
            }
            do {
                _ = try await library.rename(entry, to: title, now: now)
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        try result.get()
    }

    /// Writes every open book's pending autosave (hide).
    public func flushAll() async {
        for document in documents.values { await document.flush() }
    }

    /// Quit: marks the app as terminating (so the list survives the windows closing), then
    /// flushes and closes every book, releasing its lock.
    public func closeAllForQuit() async {
        isTerminating = true
        for id in Array(documents.keys) { await close(id) }
    }

    // MARK: Deliveries (A §6.4)

    /// A snapshot of the book for context assembly: the open document, else the package on disk.
    /// A closed book is read under its lock (serialized with this process's opens and
    /// deliveries); if another process holds the lock, it's read read-only, so nothing in the
    /// package is touched (no journal recovery, migration, ledger repair or sweep).
    public func content(for id: BookID) async -> BookContent? {
        if let document = documents[id] { return document.content }
        return await serialized(id) { [self] () async -> BookContent? in
            if let document = documents[id] { return document.content }
            guard let url = await packageURL(for: id) else { return nil }
            let store = BookStore(packageURL: url)
            switch try? await store.acquireLock() {
            case .acquired:
                let content = try? await store.load()
                await store.releaseLock()
                return content
            case .heldByOther, nil:
                await store.setReadOnly()
                return try? await store.load()
            }
        }
    }

    /// Writes a finished generation into its book, open or closed. The image file is always
    /// written before the session JSON that refers to it (A §5.2).
    ///
    /// - `.bookUnavailable`: locked by another process, open read-only here, or the image or
    ///   session couldn't be written. Nothing was applied; the queue keeps it and retries.
    /// - `.bookGone`: deleted, in the Trash, or unreadable for good (corrupt, newer schema).
    @discardableResult
    public func deliver(_ delivery: GenerationDelivery, now: @escaping @Sendable () -> Date) async -> DeliveryResult {
        let id = delivery.item.bookID
        let result: DeliveryResult = await serialized(id) { [self] in
            if let open = documents[id], !open.isClosed {
                guard open.isEditable else {
                    report(delivery, StoreErrorText.message(for: StoreError.readOnly))
                    return .bookUnavailable
                }
                let ref = await storeImage(of: delivery, in: open.store)
                if case .success = delivery.outcome, ref == nil { return .bookUnavailable }
                // Re-resolve by ID after the await (the close is serialized behind us, but be safe).
                if let document = documents[id], !document.isClosed {
                    document.performIrreversible { content in
                        BookMutations.applyDelivery(delivery, storedImage: ref, to: &content, now: now())
                    }
                    return .delivered
                }
            }
            return await deliverToClosedBook(delivery, now: now)
        }
        if result == .delivered { onDelivered(delivery.item.messageID) }
        return result
    }

    private func deliverToClosedBook(_ delivery: GenerationDelivery, now: @Sendable () -> Date) async -> DeliveryResult {
        guard let url = await packageURL(for: delivery.item.bookID) else {
            Self.log.notice("Dropped a delivery: the book is no longer in the library")
            report(delivery, "the book is no longer in the library.")
            return .bookGone
        }
        let store = BookStore(packageURL: url)
        // Take the lock before `load()`, which may recover the journal, migrate and sweep. If
        // another process has the book, nothing is written here; the queue retries later.
        do {
            if case let .heldByOther(owner) = try await store.acquireLock() { throw StoreError.locked(owner) }
        } catch {
            Self.log.error("Couldn't lock a closed book for a delivery: \(String(describing: error), privacy: .public)")
            report(delivery, StoreErrorText.message(for: error))
            return Self.result(for: error)
        }
        let result = await writeDelivery(delivery, to: store, now: now)
        await store.releaseLock()
        return result
    }

    private func writeDelivery(_ delivery: GenerationDelivery, to store: BookStore,
                               now: @Sendable () -> Date) async -> DeliveryResult {
        do {
            var content = try await store.load()
            let ref = await storeImage(of: delivery, in: store)
            if case .success = delivery.outcome, ref == nil { return .bookUnavailable }
            var dirty = BookMutations.applyDelivery(delivery, storedImage: ref, to: &content, now: now())
            guard !dirty.isEmpty else { return .delivered }
            content.book.modifiedAt = now()
            dirty.book = true
            try await store.save(content, dirty: dirty)
            return .delivered
        } catch {
            Self.log.error("Couldn't write a delivery to a closed book: \(String(describing: error), privacy: .public)")
            report(delivery, StoreErrorText.message(for: error))
            return Self.result(for: error)
        }
    }

    /// Locks, read-only and I/O problems may clear up (retry); a missing, corrupt or newer
    /// book won't (drop).
    private static func result(for error: any Error) -> DeliveryResult {
        switch error as? StoreError {
        case .notFound, .corrupt, .schemaTooNew: .bookGone
        case .locked, .readOnly, .io, .keychain, nil: .bookUnavailable
        }
    }

    // MARK: Cost ledger (A §7.10)

    /// Appends one line to the book's `costs.jsonl`, open or closed, one at a time with the
    /// book's other operations. The append is a single `O_APPEND` write, so it doesn't take the
    /// book lock: a book open in another process still gets its line. Dropped (logged) if the
    /// book is gone.
    public func recordCost(_ record: CostRecord, in id: BookID) async {
        await serialized(id) { [self] in
            guard let url = await packageURL(for: id) else {
                Self.log.notice("Dropped a ledger line: the book is no longer in the library")
                return
            }
            let ledger = CostLedger(packageURL: url)
            let failure: StoreError? = await Task.detached {
                do throws(StoreError) {
                    try ledger.append(record)
                    return nil
                } catch {
                    return error
                }
            }.value
            if let failure {
                Self.log.error("Couldn't append to the cost ledger: \(String(describing: failure), privacy: .public)")
            }
        }
    }

    /// Every ledger line of a book, read off the main actor. Empty if the book or file is gone.
    public func costRecords(for id: BookID) async -> [CostRecord] {
        guard let url = await packageURL(for: id) else { return [] }
        let ledger = CostLedger(packageURL: url)
        return await Task.detached { (try? ledger.records(CostRecord.self)) ?? [] }.value
    }

    /// Stores the image of a successful delivery; nil for failures or if the write failed (the
    /// problem is reported so the paid result doesn't vanish silently).
    private func storeImage(of delivery: GenerationDelivery, in store: BookStore) async -> ImageRef? {
        guard case let .success(result, _) = delivery.outcome else { return nil }
        do {
            return try await store.storeImage(result.imageData, contentType: result.contentType)
        } catch {
            Self.log.error("Couldn't store a generated image: \(String(describing: error), privacy: .public)")
            report(delivery, StoreErrorText.message(for: error))
            return nil
        }
    }

    private func report(_ delivery: GenerationDelivery, _ reason: String) {
        guard case .success = delivery.outcome else { return }
        onDeliveryProblem(delivery.item.messageID, "Couldn't save the picture to the book: \(reason)")
    }
}
