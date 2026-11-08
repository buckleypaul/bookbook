import BBAI
import BBAICore
import BBModel
import BBStore
import Foundation
import Observation

/// Scene identifiers shared by the app and BBUI.
public enum SceneID {
    public static let library = "library"
    public static let queue = "queue"
}

/// App-wide state (A §6.1), injected with `.environment`. Owns the library and its index, the
/// app's Keychain store, the model catalog, the generation queue and the open-books registry.
@MainActor @Observable
public final class AppModel {
    @ObservationIgnored public private(set) var library: Library
    @ObservationIgnored public private(set) var index: LibraryIndex
    @ObservationIgnored public let keychain: KeychainStore
    @ObservationIgnored public let catalog: ModelCatalog
    @ObservationIgnored public let queue: GenerationQueue
    @ObservationIgnored public let writer: BookWriter
    @ObservationIgnored public let thumbnails: ThumbnailCache
    public let openBooks: OpenBooks
    public let defaults: GenerationDefaults

    /// The library folder in use (Settings ▸ General shows it).
    public private(set) var libraryRoot: URL
    /// From `LibraryIndex`, newest first.
    public private(set) var libraryEntries: [LibraryEntry] = []
    public private(set) var queueSnapshot = QueueSnapshot()
    /// From `KeychainStore.hasKey` (never reads the secret).
    public private(set) var hasOpenAIKey = false
    /// Set by File ▸ New Book…; the Library window shows its sheet.
    public var newBookRequested = false
    /// Set by File ▸ New Book from Story…; the Library window shows the title sheet, and the new
    /// book opens with the Import Story Text sheet already up.
    public var newBookFromStoryRequested = false
    /// Books created by New Book from Story… whose window hasn't yet presented the import sheet.
    @ObservationIgnored private var pendingStoryImports: Set<BookID> = []
    /// Pictures that arrived but couldn't be written into their book, by message (shown in the thread).
    public private(set) var deliveryFailures: [MessageID: String] = [:]
    /// Book windows the app wants closed (trash, library move). Each `BookWindow` watches for its
    /// ID, dismisses itself and calls `windowDidClose`.
    public private(set) var windowCloseRequests: Set<BookID> = []

    @ObservationIgnored private var pendingThisLaunch: Set<QueueItemID> = []
    @ObservationIgnored private var enqueueChain: Task<Void, Never>?
    @ObservationIgnored private var subscription: Task<Void, Never>?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private var reopenDone = false
    @ObservationIgnored private let indexCacheURL: URL
    @ObservationIgnored private let userDefaults: UserDefaults
    @ObservationIgnored private let now: @Sendable () -> Date

    /// - Parameters:
    ///   - providers: the concrete image providers (the app wires OpenAI; tests pass fakes).
    ///   - catalog: nil loads the bundled catalog.
    ///   - indexCacheURL: where `LibraryIndex` caches the library (tests pass a temp file).
    ///   - userDefaults: holds `openBookIDs` and `libraryPath` (tests pass a suite).
    public init(providers: [ProviderID: any ImageProvider], catalog: ModelCatalog? = nil,
                libraryRoot: URL = Library.defaultRoot, keychainService: String = KeychainStore.appService,
                indexCacheURL: URL = LibraryIndex.defaultCacheURL, userDefaults: UserDefaults = .standard,
                thumbnails: ThumbnailCache = ThumbnailCache(), now: @escaping @Sendable () -> Date = { Date() }) {
        let library = Library(root: libraryRoot)
        let catalog = catalog ?? ((try? ModelCatalog.bundled()) ?? ModelCatalog(asOf: "", imageModels: []))
        let openBooks = OpenBooks(library: library, defaults: userDefaults)
        let writer = BookWriter(openBooks: openBooks, now: now)
        self.library = library
        self.index = LibraryIndex(root: libraryRoot, cacheURL: indexCacheURL)
        self.libraryRoot = libraryRoot
        self.indexCacheURL = indexCacheURL
        self.userDefaults = userDefaults
        self.thumbnails = thumbnails
        self.keychain = KeychainStore(service: keychainService)
        self.catalog = catalog
        self.openBooks = openBooks
        self.writer = writer
        self.queue = GenerationQueue(providers: providers, catalog: catalog, host: writer, now: now)
        self.defaults = GenerationDefaults(
            model: catalog.defaultImageModel(for: .openai)?.id ?? GenerationDefaults.fallbackModel)
        self.now = now
        refreshKeyStatus()
        openBooks.onDeliveryProblem = { [weak self] messageID, text in self?.deliveryFailures[messageID] = text }
        openBooks.resolveURL = { [weak self] id in await self?.resolveURL(id) }

        let queue = queue
        subscription = Task { [weak self] in
            for await snapshot in await queue.subscribe() {
                guard let self else { return }
                self.queueSnapshot = snapshot
            }
        }
    }

    // MARK: Library index (A §5.4)

    /// Loads the cached index (first paint), rescans, then follows FSEvents changes, so books
    /// copied in through Finder (or put back from the Trash) appear. Runs once per library root;
    /// later calls wait for the first.
    public func start() async {
        if let startTask {
            await startTask.value
            return
        }
        let index = index
        let task = Task { [weak self] in
            let cached = await index.loadCache()
            self?.apply(cached, from: index)
            let fresh = await index.refresh()
            self?.apply(fresh, from: index)
            let changes = await index.changes()
            guard let self, self.index === index else { return }
            self.watchTask = Task { [weak self] in
                for await entries in changes {
                    guard let self else { return }
                    self.apply(entries, from: index)
                }
            }
        }
        startTask = task
        await task.value
    }

    /// Rescans the library folder now.
    public func refreshLibrary() async {
        let index = index
        apply(await index.refresh(), from: index)
    }

    public func entry(for id: BookID) -> LibraryEntry? {
        libraryEntries.first { $0.id == id }
    }

    private func apply(_ entries: [LibraryEntry], from source: LibraryIndex) {
        guard source === index else { return }
        openBooks.remember(entries)
        libraryEntries = entries
    }

    /// `BookID → URL` through the index, rescanning once if it isn't there.
    private func resolveURL(_ id: BookID) async -> URL? {
        let index = index
        if let entry = await index.entry(for: id) { return entry.url }
        apply(await index.refresh(), from: index)
        return await index.entry(for: id)?.url
    }

    /// Creates a book in the library folder and refreshes the list.
    /// With `thenImportStory`, the book's window shows the story-import sheet when it opens
    /// (`takePendingStoryImport`).
    public func createBook(title: String, thenImportStory: Bool = false) async throws -> LibraryEntry {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let entry = try library.createBook(title: trimmed.isEmpty ? "Untitled" : trimmed, now: now())
        openBooks.remember([entry])
        if thenImportStory { pendingStoryImports.insert(entry.id) }
        await refreshLibrary()
        return entry
    }

    /// True once for a book created by New Book from Story…: its window then presents the import sheet.
    public func takePendingStoryImport(for id: BookID) -> Bool {
        pendingStoryImports.remove(id) != nil
    }

    // MARK: Library actions (PD §8.1)

    /// Copies a book (flushing it first if it's open). Returns the copy.
    public func duplicate(_ entry: LibraryEntry) async throws -> LibraryEntry {
        if let document = openBooks.document(for: entry.id) { await document.flush() }
        let library = library, now = now()
        let copy = try await Task.detached { try library.duplicate(entry, now: now) }.value
        openBooks.remember([copy])
        await refreshLibrary()
        return copy
    }

    /// Moves a book to the Trash, closing its window first (flush, then close). Not undoable
    /// (PD §8.10). Returns its URL in the Trash.
    @discardableResult
    public func trash(_ entry: LibraryEntry) async throws -> URL? {
        if openBooks.document(for: entry.id) != nil { await closeWindow(for: entry.id) }
        let library = library
        let trashed = try await Task.detached { try library.trash(entry) }.value
        await refreshLibrary()
        return trashed
    }

    /// Sets a book's title (the folder keeps its name): through its `BookDocument` if it's open
    /// (not undoable), otherwise through a headless store. Serialized with that book's opens,
    /// closes and deliveries (`OpenBooks.rename`).
    public func rename(_ entry: LibraryEntry, to title: String) async throws {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        try await openBooks.rename(entry, to: title, in: library, now: now())
        await refreshLibrary()
    }

    // MARK: Library location (Settings ▸ General)

    /// Switches to `newRoot`, saving it as `libraryPath`. With `moveBooks`, every book window is
    /// flushed and closed first, then the books are moved. On a failed move the app still uses
    /// the new folder (the books moved so far are there) and rethrows.
    public func changeLibraryLocation(to newRoot: URL, moveBooks: Bool) async throws {
        let newRoot = newRoot.standardizedFileURL
        guard newRoot != libraryRoot.standardizedFileURL else { return }
        var failure: (any Error)?
        if moveBooks {
            for id in Array(openBooks.documents.keys) { await closeWindow(for: id) }
            let library = library
            do {
                _ = try await Task.detached { try library.moveBooks(to: newRoot) }.value
            } catch {
                failure = error
            }
        }
        userDefaults.set(newRoot.path(percentEncoded: false), forKey: LibraryLocation.defaultsKey)
        await switchLibrary(to: newRoot)
        if let failure { throw failure }
    }

    /// Uses another library folder from now on: a fresh index on `root`, then `start()`.
    public func switchLibrary(to root: URL) async {
        let old = index
        watchTask?.cancel()
        watchTask = nil
        startTask = nil
        library = Library(root: root)
        index = LibraryIndex(root: root, cacheURL: indexCacheURL)
        libraryRoot = root
        libraryEntries = []
        await old.stopWatching()
        await start()
    }

    // MARK: Open books

    public func openBook(_ id: BookID, readOnly: Bool = false) async throws -> BookDocument {
        windowCloseRequests.remove(id)
        return try await openBooks.open(id, readOnly: readOnly)
    }

    public func closeBook(_ id: BookID) async {
        await openBooks.close(id)
        await refreshLibrary()
    }

    /// Flushes and closes a book, then asks its window to close.
    public func closeWindow(for id: BookID) async {
        await openBooks.close(id)
        windowCloseRequests.insert(id)
    }

    /// A book window closed itself after `closeWindow(for:)`.
    public func windowDidClose(_ id: BookID) {
        windowCloseRequests.remove(id)
    }

    /// A book window whose book isn't in the library any more (restored by SwiftUI after it was
    /// deleted): forget it silently.
    public func forgetBook(_ id: BookID) {
        openBooks.forget(id)
    }

    /// Whether the index still has the book (after `start()`).
    public func resolves(_ id: BookID) async -> Bool {
        await start()
        return await resolveURL(id) != nil
    }

    /// Reopens the books that were open at quit (A §6.1), once per launch: after the index is
    /// loaded, `open` (the scene's `openWindow(value:)`) is called for each ID it still resolves,
    /// in order; the rest are dropped silently. `openWindow(value:)` brings a window SwiftUI
    /// already restored to the front, so nothing is duplicated.
    public func reopenBooks(_ open: (BookID) -> Void) async {
        guard !reopenDone else { return }
        reopenDone = true
        await start()
        let known = Set(libraryEntries.map(\.id))
        for id in openBooks.booksToReopen(resolves: { known.contains($0) }) { open(id) }
    }

    public func flushAll() async { await openBooks.flushAll() }

    /// Called synchronously from `applicationShouldTerminate`, before any window closes.
    public func beginTermination() {
        openBooks.isTerminating = true
    }

    /// Quit: flushes and closes every book (releasing locks), keeping the open-books list.
    public func prepareForQuit() async {
        beginTermination()
        await openBooks.closeAllForQuit()
        await index.stopWatching()
    }

    // MARK: Keys (A §5.5, plan §2.2: the key goes only to the Keychain)

    public func refreshKeyStatus() {
        hasOpenAIKey = keychain.hasKey(.openai)
    }

    /// Saves a pasted key. Returns false if the text was empty.
    public func saveOpenAIKey(_ text: String) throws(StoreError) -> Bool {
        guard let key = APIKey(text) else { return false }
        defer { refreshKeyStatus() }
        try keychain.save(key, for: .openai)
        return true
    }

    public func removeOpenAIKey() throws(StoreError) {
        defer { refreshKeyStatus() }
        try keychain.delete(.openai)
    }

    // MARK: Generation

    /// Appends the pending user message (non-undoable) and enqueues the request.
    /// Returns false if the prompt is empty, the box is gone or the book is read-only.
    @discardableResult
    public func generate(prompt: String, page: PageID, box: BoxID, in document: BookDocument) -> Bool {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        let refines = document.content.placedVersion(page: page, box: box)?.id
        let (message, item) = BookMutations.makeGeneration(prompt: text, refines: refines, defaults: defaults,
                                                           bookID: document.id, page: page, box: box, now: now())
        var appended = false
        document.performIrreversible { content in
            let dirty = BookMutations.appendPendingMessage(message, page: page, box: box, to: &content)
            appended = !dirty.isEmpty
            return dirty
        }
        guard appended else { return false }
        pendingThisLaunch.insert(item.id)
        let previous = enqueueChain, queue = queue
        // Chained so presses reach the queue in order.
        enqueueChain = Task {
            await previous?.value
            await queue.enqueue(item)
        }
        return true
    }

    public func status(of message: Message) -> MessageStatus {
        MessageStatus.resolve(message, snapshot: queueSnapshot, pendingThisLaunch: pendingThisLaunch,
                              deliveryFailures: deliveryFailures) { [catalog] intent in
            catalog.imageModel(provider: intent.provider, id: intent.model)?.typicalDurationSeconds[intent.quality]
        }
    }

    /// e.g. "GPT Image 2.5 Sunburst".
    public var defaultModelName: String {
        catalog.imageModel(provider: defaults.provider, id: defaults.model)?.displayName ?? defaults.model
    }
}
