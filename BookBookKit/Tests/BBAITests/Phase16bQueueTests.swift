import BBAICore
import BBModel
import Foundation
import Testing
@testable import BBAI

/// Saves slowly (each save waits `delay`), recording what was written.
actor SlowPersistence: QueuePersistence {
    private let initial: PersistedQueue?
    private let delay: Duration
    private(set) var saves: [PersistedQueue] = []
    init(initial: PersistedQueue? = nil, delay: Duration = .milliseconds(40)) {
        self.initial = initial
        self.delay = delay
    }
    func load() async -> PersistedQueue? { initial }
    func save(_ queue: PersistedQueue) async {
        try? await Task.sleep(for: delay)
        saves.append(queue)
    }
    func last() -> PersistedQueue? { saves.last }
}

/// Holds whoever calls `wait()` until `open()`; counts arrivals.
actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var arrivals = 0
    func wait() async {
        arrivals += 1
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}

/// Phase 16b queue fixes: #21, #22, #28a, #34a, #34f, #42a.
@Suite struct Phase16bQueueTests {
    let book = SliceBook.make()

    func imageItem(_ message: String) -> QueueItem {
        QueueItem(bookID: book.content.book.id, target: book.target, messageID: MessageID(), intent: intent(message))
    }

    func checkItem(_ version: VersionID) -> QueueItem {
        QueueItem(bookID: book.content.book.id, target: book.target, messageID: MessageID(),
                  intent: GenerationIntent(messageText: "", refines: version, provider: .openai, model: visionModel.id,
                                           quality: .draft),
                  kind: .consistencyCheck(version))
    }

    /// A queue with no vision provider, so a check of `version` fails at once (`.unknown`).
    func checkFailingQueue() throws -> (GenerationQueue, VersionID) {
        var content = book.content
        let version = Version(image: ImageRef(sha256: "v", contentType: "public.png"),
                              pixelSize: PixelSize(width: 8, height: 8), source: .imported, createdAt: .distantPast)
        content.sessions[book.sessionID]?.versions = [version]
        let queue = GenerationQueue(providers: [:], catalog: try visionCatalog(),
                                    host: FakeHost(content: content, images: [version.image: Data([1])]),
                                    pricing: FakePricing())
        return (queue, version.id)
    }

    // MARK: #21

    @Test func retriedCheckGoesBeforeWaitingItems() async throws {
        let (queue, version) = try checkFailingQueue()
        let check = checkItem(version)
        await queue.enqueue([check], position: .front)
        await eventually("check failed") { await queue.snapshot().entries.first?.failure != nil }
        await queue.pause()
        let a = imageItem("A"), b = imageItem("B")
        await queue.enqueue([a, b], position: .end)
        await queue.retry(check.id)
        let snapshot = await queue.snapshot()
        #expect(snapshot.entries.map(\.id) == [check.id, a.id, b.id])
        #expect(snapshot.entries.first?.state == .waiting)
    }

    @Test func retriedCheckIsDroppedWhenItsVersionHasALiveCheck() async throws {
        let (queue, version) = try checkFailingQueue()
        let failed = checkItem(version)
        await queue.enqueue([failed], position: .front)
        await eventually("check failed") { await queue.snapshot().entries.first?.failure != nil }
        await queue.pause()
        let live = checkItem(version)
        #expect(await queue.enqueue([live], position: .front) == [live.id])
        await queue.retry(failed.id)
        #expect(await queue.snapshot().entries.map(\.id) == [live.id])
    }

    @Test func retriedImageItemStillGoesToTheEnd() async throws {
        let provider = FakeProvider(outcomes: [.failure(.invalidRequest(param: nil, nil))], gated: false)
        let queue = GenerationQueue(providers: [.openai: provider], catalog: try ModelCatalog.bundled(),
                                    host: FakeHost(content: book.content), pricing: FakePricing())
        let a = imageItem("A")
        await queue.enqueue(a)
        await eventually("failed") { await queue.snapshot().entries.first?.failure != nil }
        await queue.pause()
        let b = imageItem("B")
        await queue.enqueue(b)
        await queue.retry(a.id)
        #expect(await queue.snapshot().entries.map(\.id) == [b.id, a.id])
    }

    // MARK: #22

    @Test func checkOfAGoneBookIsDroppedQuietly() async throws {
        let host = FakeHost(content: nil)
        let vision = FakeVision()
        let queue = GenerationQueue(providers: [:], catalog: try visionCatalog(), host: host, pricing: FakePricing(),
                                    visionProviders: [.openai: vision])
        await queue.enqueue([checkItem(VersionID())], position: .front)
        await eventually("dropped") { await queue.snapshot().entries.isEmpty }
        #expect(await host.delivered().isEmpty)
        #expect(await host.recorded().isEmpty)
        #expect(await vision.received().isEmpty)
    }

    // MARK: #28a

    @Test func cancelDuringTheRegionCompositeWins() async throws {
        let b = try RegionEditPipelineTests.makeBook()
        let raw = Pixels.solidPNG(64, 48, r: 250, g: 210, b: 20)
        let host = FakeHost(content: b.book.content, images: b.images)
        let provider = FakeProvider(outcomes: [.success(RegionEditPipelineTests.rawResult(raw, size: RegionEditPipelineTests.size))],
                                    gated: false)
        let queue = GenerationQueue(providers: [.openai: provider], catalog: try ModelCatalog.bundled(), host: host,
                                    pricing: FakePricing(), now: { Date(timeIntervalSince1970: 100) })
        let gate = Gate()
        await queue.setCompositor { raw, base, mask in
            await gate.wait()
            return await RegionEditCompositor.composite(raw: raw, base: base, storedMask: mask)
        }
        let item = b.item(b.intent())
        await queue.enqueue(item)
        await eventually("compositing") { await gate.arrivals == 1 }
        await queue.cancelRunning()
        await gate.open()
        await eventually("delivery") { await host.delivered().count == 1 }
        guard case .failure(.cancelled) = try #require(await host.delivered().first).outcome else {
            Issue.record("expected a cancelled delivery")
            return
        }
        #expect(await queue.snapshot().entries.isEmpty)
        // The provider call happened, so it stays charged once.
        #expect(await host.recorded().map(\.status) == [.completed])
    }

    // MARK: #34a

    @Test func flushPersistenceWaitsForTheLastState() async throws {
        let persistence = SlowPersistence()
        let queue = GenerationQueue(providers: [:], catalog: try ModelCatalog.bundled(),
                                    host: FakeHost(content: book.content), pricing: FakePricing(),
                                    persistence: persistence)
        await queue.pause()
        let items = (0..<4).map { imageItem("item \($0)") }
        for item in items { await queue.enqueue(item) }
        await queue.flushPersistence()
        #expect(await persistence.last()?.entries.map(\.item.id) == items.map(\.id))
        // Idle: returns at once.
        await queue.flushPersistence()
    }

    // MARK: #34f

    @Test func restoredPauseCountShrinksAndClearsAtZero() async throws {
        let a = imageItem("A"), b = imageItem("B")
        let saved = PersistedQueue(entries: [PersistedQueue.Entry(item: a), PersistedQueue.Entry(item: b)])
        let provider = FakeProvider(outcomes: [.success(okResult())], gated: false)
        let host = FakeHost(content: book.content)
        let queue = GenerationQueue(providers: [.openai: provider], catalog: try ModelCatalog.bundled(), host: host,
                                    pricing: FakePricing(), persistence: FakePersistence(initial: saved))
        await queue.restore()
        #expect(await queue.snapshot().pause == .restored(count: 2))
        await queue.remove(a.id)
        #expect(await queue.snapshot().pause == .restored(count: 1))
        await queue.remove(b.id)
        #expect(await queue.snapshot().pause == nil)
        // Nothing left holds the queue: a new item runs.
        await queue.enqueue(imageItem("C"))
        await eventually("ran") { await host.delivered().contains { $0.item.intent.messageText == "C" } }
    }

    // MARK: #42a

    @Test func undeliveredPictureSurvivesAPersistRestoreRoundTrip() async throws {
        let persistence = FakePersistence()
        let sleep = FakeSleep(holdFrom: .seconds(30))
        let locked = FakeHost(content: book.content, deliveryResults: [.bookUnavailable])
        let first = GenerationQueue(providers: [.openai: FakeProvider(outcomes: [.success(okResult())], gated: false)],
                                    catalog: try ModelCatalog.bundled(), host: locked, pricing: FakePricing(),
                                    persistence: persistence, sleep: sleep.closure)
        let item = imageItem("A")
        await first.enqueue(item)
        await eventually("undelivered") { await first.snapshot().undeliveredCount == 1 }
        await first.flushPersistence()
        let saved = try #require(await persistence.last())
        let spooled = try #require(saved.undelivered.first)
        #expect(saved.undelivered.count == 1)
        #expect(spooled.item.id == item.id)
        #expect(spooled.images.map(\.data) == [okResult().imageData])
        #expect(saved.entries.isEmpty)

        // Next launch: restored, redelivered at once (no 30 s wait), same version ID and bytes.
        let host = FakeHost(content: book.content)
        let second = GenerationQueue(providers: [:], catalog: try ModelCatalog.bundled(), host: host,
                                     pricing: FakePricing(), persistence: FakePersistence(initial: saved),
                                     sleep: FakeSleep(holdFrom: .seconds(30)).closure)
        await second.restore()
        let delivered = try #require(await host.delivered().first)
        #expect(delivered.versionID == spooled.versionID)
        #expect(delivered.item.id == item.id)
        guard case let .success(result, provenance) = delivered.outcome else {
            Issue.record("expected success")
            return
        }
        #expect(result.imageData == okResult().imageData)
        #expect(result.pixelSize == okResult().pixelSize)
        #expect(provenance.intent == item.intent)
        #expect(await second.snapshot().undeliveredCount == 0)
        #expect(await second.snapshot().pause == nil)
    }

    @Test func stillLockedAtLaunchStaysUndelivered() async throws {
        let delivery = GenerationDelivery(item: imageItem("A"), outcome: .failure(.cancelled))
        let saved = PersistedQueue(entries: [], undelivered: [PersistedDelivery(token: UUID(), delivery: delivery)])
        let host = FakeHost(content: book.content, deliveryResults: [.bookUnavailable])
        let queue = GenerationQueue(providers: [:], catalog: try ModelCatalog.bundled(), host: host,
                                    pricing: FakePricing(), persistence: FakePersistence(initial: saved),
                                    sleep: FakeSleep(holdFrom: .seconds(30)).closure)
        await queue.restore()
        #expect(await host.attempts() == 1)
        #expect(await queue.snapshot().undeliveredCount == 1)
    }

    @Test func schema2FileDecodesWithNoUndelivered() throws {
        let old = PersistedQueue(schemaVersion: 2, entries: [PersistedQueue.Entry(item: imageItem("old"))])
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        json["undelivered"] = nil
        let data = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(PersistedQueue.self, from: data)
        #expect(decoded.schemaVersion == 2)
        #expect(decoded.entries == old.entries)
        #expect(decoded.undelivered.isEmpty)
    }

    @Test func spooledBytesAreNotEncoded() throws {
        let delivery = GenerationDelivery(
            item: imageItem("A"),
            outcome: .success(result: okResult(), provenance: Provenance(
                provider: .openai, model: "m", quality: .draft, outputSize: okResult().pixelSize, promptSent: "p",
                referencesSent: [], referencesOmitted: [], styleRevision: 0, storyTextIncluded: false,
                intent: intent())),
            additionalImages: [ImageRef(sha256: "abc", contentType: "public.png"): Data([9, 9])])
        let persisted = PersistedDelivery(token: UUID(), delivery: delivery)
        #expect(persisted.images.map(\.fileName) == ["\(persisted.token.uuidString).png",
                                                     "\(persisted.token.uuidString)-abc.png"])
        let decoded = try JSONDecoder().decode(PersistedDelivery.self, from: JSONEncoder().encode(persisted))
        let emptyBytes = decoded.images.allSatisfy { $0.data.isEmpty }
        #expect(emptyBytes)
        #expect(decoded.delivery == nil, "no bytes, no delivery")
    }
}
