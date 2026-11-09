import BBAI
import BBAICore
import BBModel
import BBStore
import Foundation
import Testing
@testable import BBUI

/// A host whose books are locked until `unlock()`; records what lands.
actor Phase16bHost: GenerationHost {
    private let content: BookContent
    private var locked: Bool
    private(set) var delivered: [GenerationDelivery] = []

    init(content: BookContent, locked: Bool) {
        self.content = content
        self.locked = locked
    }

    func content(for bookID: BookID) async -> BookContent? { content }
    func deliver(_ delivery: GenerationDelivery) async -> DeliveryResult {
        if locked { return .bookUnavailable }
        delivered.append(delivery)
        return .delivered
    }
    func deliveredCount() -> Int { delivered.count }
}

/// Phase 16b `QueueFileStore`: newer-schema files moved aside (#34b), undelivered pictures
/// spooled to disk (#42a), sweep protection for queued work (#29a).
@Suite struct Phase16bQueueFileTests {
    let dir = FileManager.default.temporaryDirectory.appending(path: "bbui-16b-queue-\(UUID().uuidString)")
    var files: AppSupportFiles { AppSupportFiles(folderURL: dir) }
    var spool: [String] { files.fileNames(in: AppSupportFiles.undeliveredFolderName) }

    func item(_ book: BookContent, mask: ImageRef? = nil) -> QueueItem {
        var intent = GenerationIntent(messageText: "A fox", provider: .openai, model: "gpt-image-2.5-sunburst",
                                      quality: .draft, includeStoryText: false)
        intent.regionMask = mask
        let page = book.book.pageOrder[0]
        let box = book.pages[page]!.images.keys.first!
        return QueueItem(bookID: book.book.id, target: .pageBox(page, box), messageID: MessageID(), intent: intent)
    }

    func aside() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path(percentEncoded: false))) ?? [])
            .filter { $0.hasPrefix("queue-unreadable-") }
    }

    // MARK: #34b

    @Test func newerSchemaFileIsMovedAsideNotOverwritten() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = Data(#"{"schemaVersion":99,"entries":[],"somethingNew":true}"#.utf8)
        try files.write(original, to: AppSupportFiles.queueFileName)
        let store = QueueFileStore(files: files, protection: SweepProtection())
        #expect(await store.load() == nil)
        await store.save(PersistedQueue(entries: []))
        let moved = try #require(aside().first)
        #expect(aside().count == 1)
        #expect(files.read(moved) == original)
        #expect(files.read(AppSupportFiles.queueFileName) != original)
    }

    @Test func undecodableFileIsMovedAside() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        try files.write(Data("not json".utf8), to: AppSupportFiles.queueFileName)
        let store = QueueFileStore(files: files, protection: SweepProtection())
        #expect(await store.load() == nil)
        #expect(files.read(try #require(aside().first)) == Data("not json".utf8))
        #expect(files.read(AppSupportFiles.queueFileName) == nil)
    }

    // MARK: #42a

    @Test func undeliveredPictureIsSpooledAndDeletedOnceDelivered() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let content = Fixtures.book()
        let item = item(content)
        let store = QueueFileStore(files: files, protection: SweepProtection())

        // Book locked: the picture is kept on disk, not in queue.json.
        let locked = Phase16bHost(content: content, locked: true)
        let first = GenerationQueue(providers: [.openai: Phase9Provider()], catalog: try ModelCatalog.bundled(),
                                    host: locked, pricing: CostCalculator(priceList: try PriceList.bundled()),
                                    persistence: store)
        await first.restore()
        await first.enqueue(item)
        await waitUntil { await first.snapshot().undeliveredCount == 1 }
        await first.flushPersistence()
        #expect(spool.count == 1)
        let bytes = try #require(files.read("\(AppSupportFiles.undeliveredFolderName)/\(spool[0])"))
        #expect(bytes == Phase9Harness.result().imageData)
        let json = try #require(files.read(AppSupportFiles.queueFileName))
        #expect(!String(decoding: json, as: UTF8.self).contains(bytes.base64EncodedString()))

        // Next launch, book free: redelivered from the spool, then the spool file goes.
        let host = Phase16bHost(content: content, locked: false)
        let second = GenerationQueue(providers: [:], catalog: try ModelCatalog.bundled(), host: host,
                                     pricing: CostCalculator(priceList: try PriceList.bundled()),
                                     persistence: QueueFileStore(files: files, protection: SweepProtection()))
        await second.restore()
        #expect(await host.deliveredCount() == 1)
        guard case let .success(result, _) = try #require(await host.delivered.first).outcome else {
            Issue.record("expected a success delivery")
            return
        }
        #expect(result.imageData == bytes)
        await second.flushPersistence()
        #expect(spool.isEmpty)
        #expect(await QueueFileStore(files: files).load()?.undelivered.isEmpty == true)
    }

    @Test func missingSpoolFileDropsOnlyThatDelivery() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let content = Fixtures.book()
        let success = GenerationDelivery(item: item(content), outcome: .success(
            result: Fixtures.result(), provenance: Fixtures.provenance()))
        let failure = GenerationDelivery(item: item(content), outcome: .failure(.cancelled))
        let store = QueueFileStore(files: files, protection: SweepProtection())
        let a = PersistedDelivery(token: UUID(), delivery: success), b = PersistedDelivery(token: UUID(), delivery: failure)
        await store.save(PersistedQueue(entries: [], undelivered: [a, b]))
        #expect(spool == a.images.map(\.fileName))
        try files.remove("\(AppSupportFiles.undeliveredFolderName)/\(a.images[0].fileName)")
        let loaded = try #require(await store.load())
        #expect(loaded.undelivered.map(\.token) == [b.token])
    }

    // MARK: #29a

    @Test func queuedRegionMaskIsProtectedFromTheSweep() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let content = Fixtures.book()
        let mask = ImageRef(sha256: String(repeating: "a", count: 64), contentType: "public.png")
        let protection = SweepProtection()
        let store = QueueFileStore(files: files, protection: protection)
        let queued = PersistedQueue(entries: [PersistedQueue.Entry(item: item(content, mask: mask))])
        await store.save(queued)
        #expect(protection.names(for: content.book.id) == [mask.fileName])

        // Loading at launch protects it too (a fresh store and registry).
        let fresh = SweepProtection()
        _ = await QueueFileStore(files: files, protection: fresh).load()
        #expect(fresh.names(for: content.book.id) == [mask.fileName])

        // Once the item is gone the book is cleared.
        await store.save(PersistedQueue(entries: []))
        #expect(protection.names(for: content.book.id).isEmpty)
    }
}

/// Polls until `condition` holds (or ~5 s pass).
func waitUntil(_ condition: @Sendable () async -> Bool) async {
    for _ in 0..<2500 {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(2))
    }
    Issue.record("timed out")
}
