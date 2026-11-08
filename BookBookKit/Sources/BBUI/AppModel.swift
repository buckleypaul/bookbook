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

/// App-wide state (A §6.1), injected with `.environment`. Owns the library, the app's Keychain
/// store, the model catalog, the generation queue and the open-books registry.
@MainActor @Observable
public final class AppModel {
    @ObservationIgnored public let library: Library
    @ObservationIgnored public let keychain: KeychainStore
    @ObservationIgnored public let catalog: ModelCatalog
    @ObservationIgnored public let queue: GenerationQueue
    @ObservationIgnored public let writer: BookWriter
    public let openBooks: OpenBooks
    public let defaults: GenerationDefaults

    public private(set) var libraryEntries: [LibraryEntry] = []
    public private(set) var queueSnapshot = QueueSnapshot()
    /// From `KeychainStore.hasKey` (never reads the secret).
    public private(set) var hasOpenAIKey = false
    /// Set by File ▸ New Book…; the Library window shows its sheet.
    public var newBookRequested = false

    @ObservationIgnored private var pendingThisLaunch: Set<QueueItemID> = []
    @ObservationIgnored private var enqueueChain: Task<Void, Never>?
    @ObservationIgnored private var subscription: Task<Void, Never>?
    @ObservationIgnored private let now: @Sendable () -> Date

    /// - Parameters:
    ///   - providers: the concrete image providers (the app wires OpenAI; tests pass fakes).
    ///   - catalog: nil loads the bundled catalog.
    public init(providers: [ProviderID: any ImageProvider], catalog: ModelCatalog? = nil,
                libraryRoot: URL = Library.defaultRoot, keychainService: String = KeychainStore.appService,
                now: @escaping @Sendable () -> Date = { Date() }) {
        let library = Library(root: libraryRoot)
        let catalog = catalog ?? ((try? ModelCatalog.bundled()) ?? ModelCatalog(asOf: "", imageModels: []))
        let openBooks = OpenBooks(library: library)
        let writer = BookWriter(openBooks: openBooks, now: now)
        self.library = library
        self.keychain = KeychainStore(service: keychainService)
        self.catalog = catalog
        self.openBooks = openBooks
        self.writer = writer
        self.queue = GenerationQueue(providers: providers, catalog: catalog, host: writer, now: now)
        self.defaults = GenerationDefaults(
            model: catalog.defaultImageModel(for: .openai)?.id ?? GenerationDefaults.fallbackModel)
        self.now = now
        refreshKeyStatus()

        let queue = queue
        subscription = Task { [weak self] in
            for await snapshot in await queue.subscribe() {
                guard let self else { return }
                self.queueSnapshot = snapshot
            }
        }
    }

    // MARK: Library

    public func refreshLibrary() async {
        let library = library
        let entries = await Task.detached { library.scan() }.value
        openBooks.remember(entries)
        libraryEntries = entries
    }

    /// Creates a book in the library folder and refreshes the list.
    public func createBook(title: String) async throws -> LibraryEntry {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let entry = try library.createBook(title: trimmed.isEmpty ? "Untitled" : trimmed, now: now())
        openBooks.remember([entry])
        await refreshLibrary()
        return entry
    }

    // MARK: Open books

    public func openBook(_ id: BookID) async throws -> BookDocument { try await openBooks.open(id) }
    public func closeBook(_ id: BookID) async { await openBooks.close(id) }
    public func flushAll() async { await openBooks.flushAll() }

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
    /// Returns false if the prompt is empty or the box is gone.
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
        MessageStatus.resolve(message, snapshot: queueSnapshot, pendingThisLaunch: pendingThisLaunch) { [catalog] intent in
            catalog.imageModel(provider: intent.provider, id: intent.model)?.typicalDurationSeconds[intent.quality]
        }
    }

    /// e.g. "GPT Image 2.5 Sunburst".
    public var defaultModelName: String {
        catalog.imageModel(provider: defaults.provider, id: defaults.model)?.displayName ?? defaults.model
    }
}
