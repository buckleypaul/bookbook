import BBAI
import BBAICore
import BBModel
import BBStore
import Foundation
import Testing
@testable import BBUI

// MARK: - Test doubles and harness (shared with DraftAllTests and ClosedBookLedgerTests)

/// Returns `result` for every request, optionally after `release()`.
actor Phase9Provider: ImageProvider {
    nonisolated var id: ProviderID { .openai }
    private let result: ImageResult
    private var gated: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var requests: [ImageRequest] = []

    init(result: ImageResult = Phase9Harness.result(), gated: Bool = false) {
        self.result = result
        self.gated = gated
    }

    func generate(_ request: ImageRequest,
                  progress: @escaping @Sendable (GenerationProgress) -> Void) async throws(ProviderError) -> ImageResult {
        requests.append(request)
        if gated { await withCheckedContinuation { waiters.append($0) } }
        return result
    }

    func release() {
        gated = false
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}

/// A list-models fake that counts calls and can be held until `release()`.
actor Phase9Lister: ModelLister {
    nonisolated var id: ProviderID { .openai }
    private let outcome: Result<Set<String>, ProviderError>
    private var gated: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var calls = 0

    init(_ outcome: Result<Set<String>, ProviderError>, gated: Bool = false) {
        self.outcome = outcome
        self.gated = gated
    }

    func listModelIDs() async throws(ProviderError) -> Set<String> {
        calls += 1
        if gated { await withCheckedContinuation { waiters.append($0) } }
        return try outcome.get()
    }

    func release() {
        gated = false
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}

/// Network updates the test drives.
final class Phase9Network: NetworkStatusSource, @unchecked Sendable {
    // Written once in `statusUpdates()` (before any `send`), then only read; guarded by `lock`.
    private let lock = NSLock()
    private var continuation: AsyncStream<Bool>.Continuation?

    func statusUpdates() -> AsyncStream<Bool> {
        let (stream, continuation) = AsyncStream.makeStream(of: Bool.self)
        lock.withLock { self.continuation = continuation }
        return stream
    }

    var isSubscribed: Bool { lock.withLock { continuation != nil } }

    func send(_ online: Bool) {
        lock.withLock { _ = continuation?.yield(online) }
    }
}

/// A temp folder with a library, a `UserDefaults` suite and an app-support folder; never the
/// real `~/Library/Application Support`.
@MainActor
final class Phase9Harness {
    let dir: URL
    let libraryRoot: URL
    let appSupport: AppSupportFiles
    let suiteName = "bbui-phase9-\(UUID().uuidString)"
    let defaults: UserDefaults

    init() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "bbui-phase9-\(UUID().uuidString)",
                                                               directoryHint: .isDirectory)
        libraryRoot = dir.appending(path: "Library", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
        appSupport = AppSupportFiles(folderURL: dir.appending(path: "AppSupport", directoryHint: .isDirectory))
        defaults = try #require(UserDefaults(suiteName: suiteName))
    }

    func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: dir)
    }

    func makeApp(providers: [ProviderID: any ImageProvider] = [:], listers: [ProviderID: any ModelLister] = [:],
                 network: (any NetworkStatusSource)? = nil) -> AppModel {
        AppModel(providers: providers, libraryRoot: libraryRoot, keychainService: "app.bookbook.tests-\(UUID())",
                 indexCacheURL: dir.appending(path: "library-index.json"), userDefaults: defaults,
                 thumbnails: ThumbnailCache(root: dir.appending(path: "Caches")), appSupport: appSupport,
                 listers: listers, network: network)
    }

    /// A library book (cover + one story page from the presets).
    func createBook(_ title: String = "Fox") throws -> LibraryEntry {
        try Library(root: libraryRoot).createBook(title: title, now: Fixtures.date)
    }

    nonisolated static func result() -> ImageResult {
        ImageResult(imageData: Data([7, 7, 7]), contentType: "public.png", pixelSize: PixelSize(width: 1024, height: 1024),
                    usage: TokenUsage(inputTextTokens: 100, outputImageTokens: 1000))
    }

    static func firstImageBox(_ content: BookContent) throws -> (page: PageID, box: BoxID) {
        let page = try #require(content.book.pageOrder.first)
        let template = try #require(content.pages[page].flatMap { content.template(for: $0) })
        let box = try #require(template.imageBoxes.first)
        return (page, box.id)
    }

    static func record(_ amount: Decimal, basis: CostBasis = .actual, at: Date = Fixtures.date) -> CostRecord {
        CostRecord(at: at, kind: .image, provider: .openai, model: "gpt-image-2.5-sunburst", quality: .draft,
                   target: nil, status: .completed, estimated: amount, actual: basis == .actual ? amount : nil,
                   basis: basis, priceListAsOf: "2026-11-08")
    }
}

/// Polls a main-actor condition (about 5 s).
@MainActor
func until(_ message: Comment = "condition", _ condition: @MainActor () async -> Bool) async {
    for _ in 0..<2500 {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(2))
    }
    Issue.record("timed out waiting for \(message)")
}

// MARK: - Tests

@MainActor
struct Phase9WiringTests {
    // MARK: Queue file

    @Test func queueFile_roundTripsWaitingAndFailedItems() async throws {
        let h = try Phase9Harness()
        defer { h.tearDown() }
        let store = QueueFileStore(files: h.appSupport)
        #expect(await store.load() == nil)
        let intent = GenerationIntent(messageText: "a fox", provider: .openai, model: "gpt-image-2.5-sunburst",
                                      quality: .draft)
        let item = QueueItem(bookID: BookID(), target: .pageBox(PageID(), BoxID()), messageID: MessageID(),
                             intent: intent, estimate: CostEstimate(amount: Decimal(string: "0.011"), priceListAsOf: "x"),
                             display: QueueItemDisplay(bookTitle: "Fox", pageLabel: "Page 2", boxLabel: "Image 1"),
                             enqueuedAt: Date())
        var failed = item
        failed.id = QueueItemID()
        let failure = QueueFailure(error: .refused(stage: .input, categories: ["violence"], nil),
                                   report: AssemblyReport(promptText: "p", storyTextIncluded: true, styleRevision: 2,
                                                          storyText: "story"),
                                   attempts: 1, failedAt: Date())
        let queue = PersistedQueue(entries: [.init(item: item), .init(item: failed, failure: failure),
                                             .init(item: item, wasRunning: true)])
        await store.save(queue)
        #expect(FileManager.default.fileExists(atPath: h.appSupport.url(for: AppSupportFiles.queueFileName).path))
        #expect(await store.load() == queue)

        // A newer schema is ignored rather than misread.
        var newer = queue
        newer.schemaVersion = PersistedQueue.currentSchemaVersion + 1
        await store.save(newer)
        #expect(await store.load() == nil)
    }

    /// An enqueue issued synchronously right after init waits for the restore: the restored
    /// item comes first and `queue.json` ends up holding both (nothing overwritten).
    @Test func restoreRunsBeforeTheFirstEnqueue() async throws {
        let h = try Phase9Harness()
        defer { h.tearDown() }
        let entry = try h.createBook()
        let document = try await BookDocument.open(at: entry.url)
        let (page, box) = try Phase9Harness.firstImageBox(document.content)
        let intent = GenerationIntent(messageText: "restored", provider: .openai, model: "gpt-image-2.5-sunburst",
                                      quality: .draft)
        let restored = QueueItem(bookID: entry.id, target: .pageBox(page, box), messageID: MessageID(), intent: intent)
        await QueueFileStore(files: h.appSupport).save(PersistedQueue(entries: [.init(item: restored)]))

        let app = h.makeApp()
        #expect(app.generate(prompt: "new", quality: .draft, includeStoryText: true, refines: nil, page: page, box: box,
                             in: document))
        await app.queueOperationsSettled()
        let snapshot = await app.queue.snapshot()
        #expect(snapshot.entries.map(\.id).first == restored.id)
        #expect(snapshot.entries.count == 2)
        #expect(snapshot.pause == .restored(count: 1))
        let newItem = try #require(snapshot.entries.last?.item)
        #expect(newItem.display == QueueItemDisplay(bookTitle: "Fox", pageLabel: "Page 1", boxLabel: "Image 1"))
        #expect(newItem.estimate.amount != nil)
        await until("queue.json has both items") {
            let saved = await QueueFileStore(files: h.appSupport).load()
            return saved?.entries.map(\.item.id) == [restored.id, newItem.id]
        }
        await document.close()
    }

    /// A failed item's error survives a relaunch (Phase 2 follow-up): the message shows it.
    @Test func failedItemErrorSurvivesRelaunch() async throws {
        let h = try Phase9Harness()
        defer { h.tearDown() }
        let intent = GenerationIntent(messageText: "x", provider: .openai, model: "gpt-image-2.5-sunburst", quality: .draft)
        let item = QueueItem(bookID: BookID(), target: .pageBox(PageID(), BoxID()), messageID: MessageID(), intent: intent)
        let failure = QueueFailure(error: .billing(nil), report: nil, attempts: 1, failedAt: Fixtures.date)
        await QueueFileStore(files: h.appSupport).save(PersistedQueue(entries: [.init(item: item, failure: failure)]))
        let app = h.makeApp()
        await app.queueOperationsSettled()
        await until("snapshot") { app.queueSnapshot.entries.count == 1 }
        let message = Message(id: item.messageID, role: .user, text: "x", createdAt: Fixtures.date)
        #expect(app.status(of: message) == .failed(.billing(nil)))
        let entry = try #require(app.queueSnapshot.entries.first)
        #expect(app.advice(for: entry) == RefusalAdvisor.advise(.billing(nil), context: AdviceContext(provider: .openai,
                                                                                                    report: nil)))
    }

    // MARK: Offline

    @Test func networkMonitor_drivesIsOnlineAndTheQueuePause() async throws {
        let h = try Phase9Harness()
        defer { h.tearDown() }
        let network = Phase9Network()
        let app = h.makeApp(network: network)
        await until("subscribed") { network.isSubscribed }
        network.send(false)
        await until("offline") { !app.isOnline }
        await app.queueOperationsSettled()
        #expect(await app.queue.snapshot().pause == .offline)
        network.send(true)
        await until("online") { app.isOnline }
        await app.queueOperationsSettled()
        #expect(await app.queue.snapshot().pause == nil)
    }

    // MARK: Cost decision

    @Test func regenerateEstimate_usesStoredIntentAndFeedsCostDecision() async throws {
        let h = try Phase9Harness()
        defer { h.tearDown() }
        let entry = try h.createBook()
        let app = h.makeApp()
        await app.start()
        let document = try await app.openBook(entry.id)
        let ref = ImageRef(sha256: String(repeating: "a", count: 64), contentType: "public.png")
        let size = PixelSize(width: 1024, height: 1024)
        let imported = Version(image: ref, pixelSize: size, source: .imported, createdAt: Date())
        #expect(app.regenerateEstimate(imported, page: PageID(), box: BoxID(), in: document) == nil)

        let intent = GenerationIntent(messageText: "a fox", provider: .openai, model: "gpt-image-2.5-sunburst",
                                      quality: .high)
        let provenance = Provenance(provider: .openai, model: intent.model, quality: .high, outputSize: size,
                                    promptSent: "a fox", styleRevision: 1, storyTextIncluded: false, intent: intent)
        let generated = Version(image: ref, pixelSize: size, source: .generated, createdAt: Date(), provenance: provenance)
        // Box is not in the book, so the estimate is unknown, which always needs confirmation.
        let estimate = try #require(app.regenerateEstimate(generated, page: PageID(), box: BoxID(), in: document))
        let decision = await app.costDecision(for: estimate, in: document)
        #expect(decision.needsConfirmation)
        await app.closeBook(entry.id)
    }


    @Test func costDecision_usesThresholdLedgerTotalAndBudget() async throws {
        let h = try Phase9Harness()
        defer { h.tearDown() }
        let entry = try h.createBook()
        let app = h.makeApp()
        await app.start()
        let document = try await app.openBook(entry.id)
        app.preferences.confirmThreshold = Decimal(string: "0.10")!
        try CostLedger(packageURL: entry.url).append(Phase9Harness.record(Decimal(string: "0.04")!))
        try CostLedger(packageURL: entry.url).append(Phase9Harness.record(Decimal(string: "0.03")!, basis: .estimate))

        var decision = await app.costDecision(for: CostEstimate(amount: Decimal(string: "0.05")), in: document)
        #expect(decision == CostDecision(needsConfirmation: false, overBudget: false))
        decision = await app.costDecision(for: CostEstimate(amount: Decimal(string: "0.20")), in: document)
        #expect(decision.needsConfirmation)
        decision = await app.costDecision(for: .unknown, in: document)
        #expect(decision.needsConfirmation)

        #expect(app.setBudget(Decimal(string: "0.05"), in: document))
        #expect(document.content.book.budget == Decimal(string: "0.05"))
        decision = await app.costDecision(for: CostEstimate(amount: Decimal(string: "0.01")), in: document)
        #expect(decision == CostDecision(needsConfirmation: false, overBudget: true))
        #expect(!app.setBudget(-1, in: document))
        #expect(app.setBudget(nil, in: document))
        decision = await app.costDecision(for: CostEstimate(amount: Decimal(string: "0.01")), in: document)
        #expect(!decision.overBudget)

        let summary = await app.ledgerSummary(for: entry.id)
        #expect(summary.total == Decimal(string: "0.07"))
        #expect(summary.includesEstimates)
        await app.closeBook(entry.id)
    }

    // MARK: Test connection

    @Test func testConnection_setsAvailabilityAndCountsModels() async throws {
        let h = try Phase9Harness()
        defer { h.tearDown() }
        let lister = Phase9Lister(.success(["gpt-image-2.5-sunburst", "gpt-image-2.6-sunburst", "gpt-image-2", "other"]))
        let app = h.makeApp(listers: [.openai: lister])
        #expect(app.modelAvailability.isEmpty)
        guard case let .success(count) = await app.testConnection(.openai) else {
            Issue.record("expected success")
            return
        }
        #expect(count == 4)
        #expect(app.modelAvailability["gpt-image-2.5-sunburst"] == .available)
        #expect(app.modelAvailability["gpt-image-2.6-flare"] == .unavailable(successor: nil))
        #expect(app.modelAvailability.count == app.catalog.imageModels(for: .openai).count)
        #expect(app.missingDefaultModel == nil)
    }

    @Test func testConnection_missingDefaultOffersTheSuccessor() async throws {
        let h = try Phase9Harness()
        defer { h.tearDown() }
        let lister = Phase9Lister(.success(["gpt-image-2.5-sunburst"]))
        let app = h.makeApp(listers: [.openai: lister])
        app.preferences.defaultImageModelID = "gpt-image-2"
        _ = await app.testConnection(.openai)
        #expect(app.modelAvailability["gpt-image-2"] == .unavailable(successor: "gpt-image-2.5-sunburst"))
        #expect(app.missingDefaultModel == .unavailable(successor: "gpt-image-2.5-sunburst"))
        // Switching to the successor clears the prompt.
        app.preferences.defaultImageModelID = "gpt-image-2.5-sunburst"
        #expect(app.missingDefaultModel == nil)
    }

    @Test func testConnection_failureGivesAdvice() async throws {
        let h = try Phase9Harness()
        defer { h.tearDown() }
        let lister = Phase9Lister(.failure(.invalidKey(nil)))
        let app = h.makeApp(listers: [.openai: lister])
        guard case let .failure(advice) = await app.testConnection(.openai) else {
            Issue.record("expected failure")
            return
        }
        #expect(advice == RefusalAdvisor.advise(.invalidKey(nil), context: AdviceContext(provider: .openai, report: nil)))
        #expect(app.modelAvailability.isEmpty)
    }

    /// The startup check and Settings' first appearance can overlap: one request serves both.
    @Test func testConnection_concurrentCallsShareOneRequest() async throws {
        let h = try Phase9Harness()
        defer { h.tearDown() }
        let lister = Phase9Lister(.success(["gpt-image-2.5-sunburst"]), gated: true)
        let app = h.makeApp(listers: [.openai: lister])
        async let first = app.testConnection(.openai)
        async let second = app.testConnection(.openai)
        await until("request started") { await lister.calls == 1 }
        await lister.release()
        let results = await [first, second]
        #expect(await lister.calls == 1)
        for result in results {
            guard case .success(1) = result else {
                Issue.record("expected success")
                return
            }
        }
    }

    // MARK: Catalog and pricing pushes

    @Test func imageModels_listCustomModelsAndCurrentFirst() async throws {
        let h = try Phase9Harness()
        defer { h.tearDown() }
        let app = h.makeApp()
        #expect(!app.addCustomModel(id: "x", copying: "no-such-family", provider: .openai))
        #expect(!app.addCustomModel(id: "gpt-image-2.5-sunburst", copying: "gpt-image-2.5-sunburst", provider: .openai))
        #expect(app.addCustomModel(id: " my-snapshot ", copying: "gpt-image-2.5-sunburst", provider: .openai))
        #expect(!app.addCustomModel(id: "my-snapshot", copying: "gpt-image-2.5-sunburst", provider: .openai))
        let ids = app.imageModels(for: .openai).map(\.id)
        #expect(ids.contains("my-snapshot"))
        let statuses = app.imageModels(for: .openai).map(\.status)
        #expect(statuses == statuses.sorted { ($0 == .current ? 0 : 1) < ($1 == .current ? 0 : 1) })

        app.preferences.defaultImageModelID = "my-snapshot"
        let spec = try #require(app.preferences.customModels.first)
        app.removeCustomModel(spec)
        #expect(app.catalog.imageModel(provider: .openai, id: "my-snapshot") == nil)
        #expect(app.preferences.defaultImageModelID == "gpt-image-2.5-sunburst")
    }

    /// A custom model only runs if the queue has the new catalog, and the ledger line's actual
    /// cost only matches the saved price list if the queue has the new prices. Also covers the
    /// open-book ledger append and `Provenance.cost`.
    @Test func catalogAndPricingChangesReachTheQueue() async throws {
        let h = try Phase9Harness()
        defer { h.tearDown() }
        let entry = try h.createBook()
        let provider = Phase9Provider()
        let app = h.makeApp(providers: [.openai: provider])
        await app.start()
        let document = try await app.openBook(entry.id)
        let (page, box) = try Phase9Harness.firstImageBox(document.content)

        #expect(app.addCustomModel(id: "my-snapshot", copying: "gpt-image-2.5-sunburst", provider: .openai))
        app.preferences.defaultImageModelID = "my-snapshot"
        var list = app.prices.current
        let index = try #require(list.entries.firstIndex { $0.model == "gpt-image-2.5-sunburst" })
        list.entries[index].perMillionTokens["imageOut"] = 1000
        try app.prices.save(list)
        let expected = CostCalculator(priceList: list)
            .actualCost(of: try #require(Phase9Harness.result().usage), provider: .openai, model: "gpt-image-2.5-sunburst")

        #expect(app.generate(prompt: "a fox", quality: .draft, includeStoryText: true, refines: nil, page: page, box: box,
                             in: document))
        await until("delivered") {
            document.content.pages[page]?.images[box]?.placement != nil
        }
        let records = await app.openBooks.costRecords(for: entry.id)
        #expect(records.count == 1)
        let record = try #require(records.first)
        #expect(record.model == "my-snapshot")
        #expect(record.basis == .actual)
        #expect(record.actual == expected)
        let slot = try #require(document.content.pages[page]?.images[box])
        let version = try #require(document.content.sessions[slot.sessionID]?.versions.first)
        #expect(version.provenance?.cost == record.id)
        #expect(await app.costRecord(record.id, in: entry.id) == record)
        #expect(await app.ledgerSummary(for: entry.id).total == record.amount)
        await app.closeBook(entry.id)
    }

    // MARK: Queue controls

    @Test func queueControls_forwardToTheQueue() async throws {
        let h = try Phase9Harness()
        defer { h.tearDown() }
        let entry = try h.createBook()
        let app = h.makeApp()
        await app.start()
        let document = try await app.openBook(entry.id)
        let (page, box) = try Phase9Harness.firstImageBox(document.content)
        app.pauseQueue()
        for prompt in ["one", "two", "three"] {
            #expect(app.generate(prompt: prompt, quality: .draft, includeStoryText: false, refines: nil, page: page,
                                 box: box, in: document))
        }
        await app.queueOperationsSettled()
        var snapshot = await app.queue.snapshot()
        #expect(snapshot.pause == .user)
        let ids = snapshot.entries.map(\.id)
        #expect(ids.count == 3)
        app.moveQueueItem(ids[2], to: 0)
        await app.queueOperationsSettled()
        snapshot = await app.queue.snapshot()
        #expect(snapshot.entries.map(\.id) == [ids[2], ids[0], ids[1]])
        app.removeQueueItem(ids[0])
        await app.queueOperationsSettled()
        snapshot = await app.queue.snapshot()
        #expect(snapshot.entries.map(\.id) == [ids[2], ids[1]])
        // The removed item's message is cleared (delivered as cancelled).
        await until("message cleared") {
            let session = document.content.sessions[document.content.pages[page]!.images[box]!.sessionID]
            return session?.messages.first { $0.text == "one" }?.queueItemID == nil
        }
        await app.closeBook(entry.id)
    }
}
