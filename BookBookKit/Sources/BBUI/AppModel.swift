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

/// Which New Book sheet the Library window shows (`AppModel.newBookRequest`).
public enum NewBookKind: Hashable, Identifiable, Sendable {
    case blank
    case fromStory

    public var id: Self { self }
}

/// App-wide state (A §6.1), injected with `.environment`. Owns the library and its index, the
/// app's Keychain store, the model catalog, the generation queue and the open-books registry.
@MainActor @Observable
public final class AppModel {
    @ObservationIgnored public private(set) var library: Library
    @ObservationIgnored public private(set) var index: LibraryIndex
    @ObservationIgnored public let keychain: KeychainStore
    /// The effective catalog: the bundled one plus the custom model IDs in `preferences`
    /// (A §7.1 item 3). Pushed to the queue whenever it changes.
    public private(set) var catalog: ModelCatalog
    /// The catalog as shipped (custom models copy a family from here).
    @ObservationIgnored public let bundledCatalog: ModelCatalog
    @ObservationIgnored public let queue: GenerationQueue
    /// Phase 12: the template-generation provider (A §7.7), set by the app's wiring. nil = AI
    /// templates unavailable.
    @ObservationIgnored public var layoutProvider: (any LayoutProvider)?
    @ObservationIgnored public let writer: BookWriter
    @ObservationIgnored public let thumbnails: ThumbnailCache
    public let openBooks: OpenBooks
    /// What a Generate press uses: the Settings default model and quality (`preferences`).
    public var defaults: GenerationDefaults {
        GenerationDefaults(provider: .openai, model: preferences.defaultImageModelID,
                           quality: preferences.defaultQuality)
    }
    /// Phase 9: default model/quality, threshold and custom models (Settings).
    public let preferences: AppPreferences
    /// Phase 9: the effective price list (bundled or the user's copy).
    public let prices: PriceBook
    /// Phase 9: app-level files (`queue.json`, `pricelist.json`). Tests pass a temp folder.
    @ObservationIgnored public let appSupport: AppSupportFiles
    /// Phase 9: list-models availability per model ID, after Test connection or opening Settings.
    public internal(set) var modelAvailability: [String: ModelAvailability] = [:]
    /// Phase 9: false while `NWPathMonitor` reports no network ("Offline").
    public internal(set) var isOnline = true
    /// Phase 9: the chosen default model disappeared from the provider's list; Settings and the
    /// session panel offer to switch (to the catalog successor when there is one).
    public internal(set) var missingDefaultModel: ModelAvailability?

    /// The library folder in use (Settings ▸ General shows it).
    public private(set) var libraryRoot: URL
    /// From `LibraryIndex`, newest first.
    public private(set) var libraryEntries: [LibraryEntry] = []
    public private(set) var queueSnapshot = QueueSnapshot()
    /// From `KeychainStore.hasKey` (never reads the secret).
    public private(set) var hasOpenAIKey = false
    /// Set by File ▸ New Book… (`.blank`) or New Book from Story… (`.fromStory`); the Library window
    /// shows the New Book sheet. From story, the new book opens with the Import Story Text sheet
    /// already up. One value, so the two kinds never collide.
    public var newBookRequest: NewBookKind?
    /// Books created by New Book from Story… whose window hasn't yet presented the import sheet.
    @ObservationIgnored private var pendingStoryImports: Set<BookID> = []
    /// Pictures that arrived but couldn't be written into their book, by message (shown in the thread).
    public private(set) var deliveryFailures: [MessageID: String] = [:]
    /// Book windows the app wants closed (trash, library move). Each `BookWindow` watches for its
    /// ID, dismisses itself and calls `windowDidClose`.
    public private(set) var windowCloseRequests: Set<BookID> = []

    @ObservationIgnored private var pendingThisLaunch: Set<QueueItemID> = []
    /// Every call into the queue that can change it, in order. Starts with `restore()`, so
    /// nothing is enqueued (and no save can overwrite `queue.json`) before the restore is done.
    @ObservationIgnored private var queueChain: Task<Void, Never>?
    @ObservationIgnored private var subscription: Task<Void, Never>?
    @ObservationIgnored private var networkTask: Task<Void, Never>?
    @ObservationIgnored let listers: [ProviderID: any ModelLister]
    /// Model IDs from the last successful list-models call, per provider.
    @ObservationIgnored var listedModels: [ProviderID: Set<String>] = [:]
    /// A list-models call in flight, shared by concurrent callers (startup check and Settings).
    @ObservationIgnored var connectionTests: [ProviderID: Task<ConnectionTestResult, Never>] = [:]
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private var reopenDone = false
    @ObservationIgnored private let indexCacheURL: URL
    @ObservationIgnored private let userDefaults: UserDefaults
    @ObservationIgnored let now: @Sendable () -> Date
    /// Phase 12: the providers wired for the consistency check (A §7.8).
    @ObservationIgnored let visionProviderIDs: Set<ProviderID>
    /// Phase 12 seams (tests replace them; the defaults are the BBAI functions).
    @ObservationIgnored var consistencyEstimator: (CatalogTextModel, Int, PriceList) -> CostEstimate = {
        CostEstimator.estimateConsistency(model: $0, imageCount: $1, priceList: $2)
    }
    @ObservationIgnored var correctionMessage: ([ConsistencyDifference]) -> String = {
        ConsistencyPrompt.correctionMessage($0)
    }

    /// - Parameters:
    ///   - providers: the concrete image providers (the app wires OpenAI; tests pass fakes).
    ///   - catalog: nil loads the bundled catalog.
    ///   - indexCacheURL: where `LibraryIndex` caches the library (tests pass a temp file).
    ///   - userDefaults: holds `openBookIDs` and `libraryPath` (tests pass a suite).
    ///   - appSupport: where `queue.json` and `pricelist.json` live (tests pass a temp folder).
    ///   - listers: list-models clients for Test connection and model availability.
    ///   - network: online/offline updates (the app passes `NetworkMonitor`); nil = always online.
    ///   - priceList: nil uses the bundled price list (or the user's copy in `appSupport`).
    ///   - visionProviders: Phase 12 consistency-check providers (the app wires OpenAI; tests pass
    ///     fakes). Empty = no checks: no follow-ups are queued or estimated, and on-demand checks
    ///     are refused (`canCheckConsistency`).
    public init(providers: [ProviderID: any ImageProvider], catalog: ModelCatalog? = nil,
                libraryRoot: URL = Library.defaultRoot, keychainService: String = KeychainStore.appService,
                indexCacheURL: URL = LibraryIndex.defaultCacheURL, userDefaults: UserDefaults = .standard,
                thumbnails: ThumbnailCache = ThumbnailCache(), appSupport: AppSupportFiles = AppSupportFiles(),
                listers: [ProviderID: any ModelLister] = [:], network: (any NetworkStatusSource)? = nil,
                priceList: PriceList? = nil, now: @escaping @Sendable () -> Date = { Date() },
                visionProviders: [ProviderID: any VisionProvider] = [:]) {
        let library = Library(root: libraryRoot)
        let bundledCatalog = catalog ?? ((try? ModelCatalog.bundled()) ?? ModelCatalog(asOf: "", imageModels: []))
        let openBooks = OpenBooks(library: library, defaults: userDefaults)
        let writer = BookWriter(openBooks: openBooks, now: now)
        let preferences = AppPreferences(
            defaults: userDefaults,
            fallbackModelID: bundledCatalog.defaultImageModel(for: .openai)?.id ?? GenerationDefaults.fallbackModel)
        let prices = PriceBook(files: appSupport, bundled: priceList)
        let effective = bundledCatalog.adding(preferences.customModels)
        self.library = library
        self.index = LibraryIndex(root: libraryRoot, cacheURL: indexCacheURL)
        self.libraryRoot = libraryRoot
        self.indexCacheURL = indexCacheURL
        self.userDefaults = userDefaults
        self.thumbnails = thumbnails
        self.keychain = KeychainStore(service: keychainService)
        self.bundledCatalog = bundledCatalog
        self.catalog = effective
        self.openBooks = openBooks
        self.writer = writer
        self.queue = GenerationQueue(providers: providers, catalog: effective, host: writer, pricing: prices.calculator,
                                     persistence: QueueFileStore(files: appSupport), now: now,
                                     visionProviders: visionProviders)
        self.visionProviderIDs = Set(visionProviders.keys)
        self.appSupport = appSupport
        self.preferences = preferences
        self.prices = prices
        self.listers = listers
        self.now = now
        refreshKeyStatus()
        openBooks.onDeliveryProblem = { [weak self] messageID, text in self?.deliveryFailures[messageID] = text }
        openBooks.onDelivered = { [weak self] messageID in self?.deliveryFailures[messageID] = nil }
        openBooks.resolveURL = { [weak self] id in await self?.resolveURL(id) }
        preferences.onCustomModelsChange = { [weak self] in self?.rebuildCatalog() }
        preferences.onDefaultModelChange = { [weak self] in self?.refreshAvailability() }
        prices.onChange = { [weak self] list in
            let pricing = CostCalculator(priceList: list)
            self?.queueOperation { await $0.setPricing(pricing) }
        }

        let queue = queue
        subscription = Task { [weak self] in
            for await snapshot in await queue.subscribe() {
                guard let self else { return }
                self.queueSnapshot = snapshot
            }
        }
        // The restore heads the chain: enqueues, pauses and online changes all wait for it.
        queueChain = Task { await queue.restore() }
        if let network {
            networkTask = Task { [weak self] in
                for await online in network.statusUpdates() {
                    guard let self else { return }
                    self.setOnline(online)
                }
            }
        }
        checkModelsQuietly()
    }

    // MARK: Queue plumbing

    /// Runs `operation` on the queue after every earlier queue operation (the first is the
    /// restore), so calls arrive in order and never before `queue.json` is loaded.
    func queueOperation(_ operation: @escaping @Sendable (GenerationQueue) async -> Void) {
        let previous = queueChain, queue = queue
        queueChain = Task {
            await previous?.value
            await operation(queue)
        }
    }

    /// Waits for every queue operation issued so far (tests, and callers that need the
    /// restored queue).
    public func queueOperationsSettled() async {
        await queueChain?.value
    }

    private func setOnline(_ online: Bool) {
        if isOnline != online { isOnline = online }
        queueOperation { await $0.setOnline(online) }
    }

    /// Bundled plus custom models; pushed to the queue (used from the next item that starts).
    private func rebuildCatalog() {
        catalog = bundledCatalog.adding(preferences.customModels)
        let catalog = catalog
        queueOperation { await $0.setCatalog(catalog) }
        refreshAvailability()
    }

    /// Lists models in the background when a key exists, so availability is known when
    /// Settings opens. Failures are silent (Settings' Test connection shows them).
    private func checkModelsQuietly() {
        guard hasOpenAIKey, listers[.openai] != nil else { return }
        Task { [weak self] in _ = await self?.testConnection(.openai) }
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
        let openBooks = openBooks
        let task = Task { [weak self] in
            // Duplicate-id resolution never rewrites a package that has a window open.
            await index.setOpenPackages { Set(openBooks.documents.values.map(\.store.packageURL)) }
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

    /// Creates a book from the new-book wizard's `spec` (PD §8.13). Creation, not an edit: there
    /// is no `BookCommand` and the new book's undo stack starts empty. With `importStoryAfter`,
    /// the book's window shows the story-import sheet when it opens (`takePendingStoryImport`).
    public func createBook(spec: NewBookSpec) async throws -> LibraryEntry {
        let library = library, now = now()
        // File I/O off the main actor (#3g).
        let entry = try await Task.detached { try library.createBook(spec: spec, now: now) }.value
        openBooks.remember([entry])
        if spec.importStoryAfter { pendingStoryImports.insert(entry.id) }
        await refreshLibrary()
        return entry
    }

    /// `UserDefaults` key holding the `BookID` (UUID string) of this user's copy of the sample book.
    public static let sampleBookIDKey = "sampleBookCopyID"

    /// "Open Sample Book": the library copy of the bundled sample (A §5.4). The first use copies it
    /// into the library under a new `Book.id` and remembers that ID; later uses return the same
    /// book while it is still in the library, and copy again if the user deleted it. No API key needed.
    public func sampleBookEntry() async throws -> LibraryEntry {
        if let text = userDefaults.string(forKey: Self.sampleBookIDKey), let uuid = UUID(uuidString: text) {
            let id = BookID(rawValue: uuid)
            if let existing = entry(for: id) { return existing }
            await refreshLibrary()
            if let existing = entry(for: id) { return existing }
        }
        guard let source = SampleBook.bundledURL() else { throw StoreError.notFound("SampleBook/Sample.bookbook") }
        let library = library, now = now()
        let copy = try await Task.detached { try library.installSample(from: source, now: now) }.value
        userDefaults.set(copy.id.rawValue.uuidString, forKey: Self.sampleBookIDKey)
        openBooks.remember([copy])
        await refreshLibrary()
        return copy
    }

    /// Set when Open Sample Book fails; the Library window shows it.
    public var sampleBookError: String?

    /// File ▸ Open Sample Book: copies the sample on first use, then opens it through `open`.
    public func openSampleBook(open: @MainActor (BookID) -> Void) async {
        do {
            open(try await sampleBookEntry().id)
        } catch {
            sampleBookError = StoreErrorText.message(for: error)
        }
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
    /// Also drops a story import the window never presented (#72b).
    public func windowDidClose(_ id: BookID) {
        windowCloseRequests.remove(id)
        pendingStoryImports.remove(id)
    }

    /// A book window whose book isn't in the library any more (restored by SwiftUI after it was
    /// deleted): forget it silently, with any pending story import.
    public func forgetBook(_ id: BookID) {
        openBooks.forget(id)
        pendingStoryImports.remove(id)
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

    /// Quit: flushes and closes every book (releasing locks), keeping the open-books list, then
    /// waits for the queue's last `queue.json` save (#34a).
    public func prepareForQuit() async {
        beginTermination()
        await openBooks.closeAllForQuit()
        await index.stopWatching()
        await queueOperationsSettled()
        await queue.flushPersistence()
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
        refreshKeyStatus()
        listedModels[.openai] = nil
        refreshAvailability()
        checkModelsQuietly()
        return true
    }

    public func removeOpenAIKey() throws(StoreError) {
        defer { refreshKeyStatus() }
        try keychain.delete(.openai)
        listedModels[.openai] = nil
        refreshAvailability()
    }

    // MARK: Generation

    /// Appends the pending user message (non-undoable) and enqueues the request. `refines` is
    /// the panel's selected version (nil = a new image). Returns false if the prompt is empty,
    /// the box is gone or the book is read-only.
    @discardableResult
    public func generate(prompt: String, quality: QualityLevel, includeStoryText: Bool, refines: VersionID?,
                         page: PageID, box: BoxID, in document: BookDocument) -> Bool {
        generate(prompt: prompt, quality: quality, includeStoryText: includeStoryText, refines: refines,
                 attachedReferences: [], target: .pageBox(page, box), in: document)
    }

    /// "Regenerate with same settings": a new pending message and queue item built from the
    /// version's stored intent, unchanged (same text, same `refines`), for any target. False for
    /// versions with no provenance (imported) or a target that's gone.
    @discardableResult
    public func regenerate(_ version: Version, target: GenerationTarget, in document: BookDocument) -> Bool {
        guard let intent = (version.provenance?.intent).map(replayed) else { return false }
        let (message, item) = BookMutations.makeGeneration(intent: intent, bookID: document.id, target: target,
                                                           now: now())
        return enqueue(message, prepared(item, content: document.content), in: document)
    }

    /// A stored intent replayed now: unchanged, except the consistency follow-up follows today's
    /// Settings switch (it's captured at enqueue time, A §7.8), and `versionSource` is cleared:
    /// a replay is a plain generation, not another consistency fix (#18).
    func replayed(_ intent: GenerationIntent) -> GenerationIntent {
        var intent = intent
        intent.checkConsistency = preferences.consistencyCheckEnabled
        intent.versionSource = nil
        return intent
    }

    /// Fills in the item's estimate, display labels and enqueue time (A §7.9, §7.10), and its
    /// consistency follow-up (A §7.8): `checkConsistency` defaults to the Settings switch.
    func prepared(_ item: QueueItem, content: BookContent) -> QueueItem {
        var item = item
        if item.intent.checkConsistency == nil { item.intent.checkConsistency = preferences.consistencyCheckEnabled }
        item.estimate = ownEstimate(item.intent, target: item.target, content: content)
        item.consistencyFollowUp = consistencyFollowUp(for: item.intent, target: item.target, content: content)
        switch item.target {
        case let .pageBox(page, box):
            item.display = DraftAllPlanner.display(page: page, box: box, in: content)
        case .assetReference, .sheetItem:
            item.display = AssetQueueDisplay.display(item.target.owner, in: content)
        }
        item.enqueuedAt = now()
        return item
    }

    /// What the user is shown for a generation: its own request plus its consistency follow-up
    /// when one would be queued (`intent.checkConsistency`, nil = the Settings switch; A §7.10).
    func estimate(_ intent: GenerationIntent, target: GenerationTarget, content: BookContent) -> CostEstimate {
        let own = ownEstimate(intent, target: target, content: content)
        guard let followUp = consistencyFollowUp(for: intent, target: target, content: content) else { return own }
        return CostEstimate.total([own, followUp.estimate])
    }

    /// `CostEstimator` on the effective catalog and the current price list for this request
    /// alone (the queue item's `estimate`); `.unknown` if the model or target can't be resolved
    /// or the model has no price entry.
    func ownEstimate(_ intent: GenerationIntent, target: GenerationTarget, content: BookContent) -> CostEstimate {
        guard let input = CostEstimator.estimateInput(intent: intent, target: target, content: content,
                                                      catalog: catalog) else { return .unknown }
        return CostEstimator.estimate(input, priceList: prices.current)
    }

    /// Whether a session message still has a live request (waiting, running or retrying).
    func isPending(_ message: Message) -> Bool {
        guard let id = message.queueItemID else { return false }
        if let entry = queueSnapshot.entry(for: id) {
            if case .failed = entry.state { return false }
            return true
        }
        return pendingThisLaunch.contains(id)
    }

    func notePending(_ ids: some Sequence<QueueItemID>) {
        pendingThisLaunch.formUnion(ids)
    }

    func enqueue(_ message: Message, _ item: QueueItem, in document: BookDocument) -> Bool {
        var appended = false
        document.performIrreversible { content in
            let dirty = BookMutations.appendPendingMessage(message, target: item.target, to: &content)
            appended = !dirty.isEmpty
            return dirty
        }
        guard appended else { return false }
        pendingThisLaunch.insert(item.id)
        // Chained (after the restore) so presses reach the queue in order.
        queueOperation { await $0.enqueue([item], position: .end) }
        return true
    }

    public func status(of message: Message) -> MessageStatus {
        MessageStatus.resolve(message, snapshot: queueSnapshot, pendingThisLaunch: pendingThisLaunch,
                              deliveryFailures: deliveryFailures) { typicalDuration(for: $0) }
    }

    /// The model's typical seconds for a queue item: the image model at its quality, or the
    /// vision model for a consistency check. Nil when the catalog doesn't say.
    func typicalDuration(for item: QueueItem) -> Double? {
        let intent = item.intent
        return item.kind == .image
            ? catalog.imageModel(provider: intent.provider, id: intent.model)?.typicalDurationSeconds[intent.quality]
            : catalog.textModel(provider: intent.provider, id: intent.model)?.typicalDurationSeconds
    }

    /// e.g. "GPT Image 2.5 Sunburst".
    public var defaultModelName: String {
        catalog.imageModel(provider: defaults.provider, id: defaults.model)?.displayName ?? defaults.model
    }
}
