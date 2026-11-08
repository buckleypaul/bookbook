import BBAICore
import BBModel
import Foundation
import Testing
@testable import BBAI

/// Fake provider: each call waits for `release()` (or Task cancellation), then returns the scripted outcome.
actor FakeProvider: ImageProvider {
    nonisolated let id = ProviderID.openai
    private var outcomes: [Result<ImageResult, ProviderError>]
    private(set) var started: [String] = []
    private var released = 0
    private let gated: Bool

    init(outcomes: [Result<ImageResult, ProviderError>], gated: Bool = true) {
        self.outcomes = outcomes
        self.gated = gated
    }

    func release(_ count: Int = 1) { released += count }
    func startedPrompts() -> [String] { started }

    private func begin(_ prompt: String) -> Result<ImageResult, ProviderError> {
        started.append(prompt)
        return outcomes.isEmpty ? .failure(.unknown(nil)) : outcomes.removeFirst()
    }

    private func take(_ index: Int) -> Bool { released > index }

    nonisolated func generate(_ request: ImageRequest, progress: @escaping @Sendable (GenerationProgress) -> Void)
        async throws(ProviderError) -> ImageResult {
        let outcome = await begin(request.instruction.rendered)
        let index = await started.count - 1
        progress(.sent)
        if gated {
            while await !take(index) {
                if Task.isCancelled { throw .cancelled }
                try? await Task.sleep(for: .milliseconds(2))
            }
        }
        if Task.isCancelled { throw .cancelled }
        return try outcome.get()
    }
}

actor FakeHost: GenerationHost {
    var content: BookContent?
    private(set) var deliveries: [GenerationDelivery] = []

    init(content: BookContent?) { self.content = content }

    func content(for bookID: BookID) async -> BookContent? { content }
    func deliver(_ delivery: GenerationDelivery) async { deliveries.append(delivery) }
    func delivered() -> [GenerationDelivery] { deliveries }
}

func okResult() -> ImageResult {
    ImageResult(imageData: Data([1, 2, 3]), contentType: "public.png", pixelSize: PixelSize(width: 1024, height: 672),
                usage: TokenUsage(outputImageTokens: 7), revisedPrompt: "revised",
                parametersSent: ["size": "1024x672", "quality": "low"])
}

/// Polls until `condition` holds (or fails after ~5 s).
func eventually(_ message: Comment = "condition", _ condition: @Sendable () async -> Bool) async {
    for _ in 0..<2500 {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(2))
    }
    Issue.record("timed out waiting for \(message)")
}

@Suite struct GenerationQueueTests {
    let book = SliceBook.make()

    func makeItem(_ message: String = "A fox") -> QueueItem {
        QueueItem(bookID: book.content.book.id, target: book.target, messageID: MessageID(), intent: intent(message))
    }

    func makeQueue(_ provider: FakeProvider, host: FakeHost? = nil) throws -> (GenerationQueue, FakeHost) {
        let host = host ?? FakeHost(content: book.content)
        let queue = GenerationQueue(providers: [.openai: provider], catalog: try ModelCatalog.bundled(), host: host,
                                    now: { Date(timeIntervalSince1970: 100) })
        return (queue, host)
    }

    @Test func successDeliversProvenanceAndRemovesEntry() async throws {
        let provider = FakeProvider(outcomes: [.success(okResult())], gated: false)
        let (queue, host) = try makeQueue(provider)
        let item = makeItem("A fox")
        await queue.enqueue(item)
        await eventually("delivery") { await host.delivered().count == 1 }
        let delivery = try #require(await host.delivered().first)
        guard case let .success(result, provenance) = delivery.outcome else {
            Issue.record("expected success")
            return
        }
        let sent = try #require(await provider.startedPrompts().first)
        #expect(provenance.promptSent == sent)
        #expect(provenance.parametersSent == ["size": "1024x672", "quality": "low"])
        #expect(provenance.outputSize == PixelSize(width: 1024, height: 672))
        #expect(provenance.model == "gpt-image-2.5-sunburst")
        #expect(provenance.provider == .openai)
        #expect(provenance.quality == .draft)
        #expect(provenance.styleRevision == 3)
        #expect(provenance.storyTextIncluded)
        #expect(provenance.intent == item.intent)
        #expect(provenance.revisedPrompt == "revised")
        #expect(provenance.usage == TokenUsage(outputImageTokens: 7))
        #expect(result.imageData == Data([1, 2, 3]))
        #expect(delivery.item == item)
        await eventually("entry removed") { await queue.snapshot().entries.isEmpty }
    }

    @Test func failureStaysFailedAndNextItemRuns() async throws {
        let provider = FakeProvider(outcomes: [.failure(.refused(stage: .input, categories: ["x"], nil)), .success(okResult())],
                                    gated: false)
        let (queue, host) = try makeQueue(provider)
        let first = makeItem("one"), second = makeItem("two")
        await queue.enqueue(first)
        await queue.enqueue(second)
        await eventually("two deliveries") { await host.delivered().count == 2 }
        let deliveries = await host.delivered()
        guard case .failure(.refused) = deliveries[0].outcome, case .success = deliveries[1].outcome else {
            Issue.record("unexpected outcomes")
            return
        }
        await eventually("settled") { await queue.snapshot().entries.count == 1 }
        let snapshot = await queue.snapshot()
        #expect(snapshot.entry(for: first.id)?.state == .failed(.refused(stage: .input, categories: ["x"], nil)))
        #expect(snapshot.entry(for: second.id) == nil)
        // Failed entries can be removed.
        await queue.remove(first.id)
        #expect(await queue.snapshot().entries.isEmpty)
    }

    @Test func itemsRunSeriallyAndRunningCannotBeRemoved() async throws {
        let provider = FakeProvider(outcomes: [.success(okResult()), .success(okResult())])
        let (queue, host) = try makeQueue(provider)
        let first = makeItem("one"), second = makeItem("two")
        await queue.enqueue(first)
        await queue.enqueue(second)
        await eventually("first started") { await provider.startedPrompts().count == 1 }
        try await Task.sleep(for: .milliseconds(50))
        #expect(await provider.startedPrompts().count == 1)
        let running = await queue.snapshot()
        #expect(running.entry(for: first.id)?.state == .running(startedAt: Date(timeIntervalSince1970: 100), progress: nil)
                || running.entry(for: first.id)?.state == .running(startedAt: Date(timeIntervalSince1970: 100), progress: .sent))
        #expect(running.entry(for: second.id)?.state == .waiting)
        await queue.remove(first.id)
        #expect(await queue.snapshot().entries.count == 2)

        await provider.release()
        await eventually("second started") { await provider.startedPrompts().count == 2 }
        #expect(await host.delivered().count == 1)
        await provider.release()
        await eventually("both delivered") { await host.delivered().count == 2 }
        let prompts = await provider.startedPrompts()
        #expect(prompts[0].contains("one") && prompts[1].contains("two"))
    }

    @Test func cancelRunningDeliversCancelledAndRemovesEntry() async throws {
        let provider = FakeProvider(outcomes: [.success(okResult()), .success(okResult())])
        let (queue, host) = try makeQueue(provider)
        let first = makeItem("one"), second = makeItem("two")
        await queue.enqueue(first)
        await queue.enqueue(second)
        await eventually("started") { await provider.startedPrompts().count == 1 }
        await queue.cancelRunning()
        await eventually("cancel delivered") { await host.delivered().count == 1 }
        guard case .failure(.cancelled) = await host.delivered()[0].outcome else {
            Issue.record("expected cancelled")
            return
        }
        #expect(await queue.snapshot().entry(for: first.id) == nil)
        // The queue carries on with the next item.
        await eventually("second started") { await provider.startedPrompts().count == 2 }
        await provider.release(2)
        await eventually("second delivered") { await host.delivered().count == 2 }
    }

    @Test func missingBookOrModelFails() async throws {
        let provider = FakeProvider(outcomes: [], gated: false)
        let (queue, host) = try makeQueue(provider, host: FakeHost(content: nil))
        let item = makeItem()
        await queue.enqueue(item)
        await eventually("delivery") { await host.delivered().count == 1 }
        guard case .failure(.unknown) = await host.delivered()[0].outcome else {
            Issue.record("expected unknown")
            return
        }
        #expect(await queue.snapshot().entry(for: item.id)?.state == .failed(.unknown(nil)))

        var badModel = makeItem()
        badModel.intent.model = "nope"
        let (queue2, host2) = try makeQueue(provider)
        await queue2.enqueue(badModel)
        await eventually("delivery 2") { await host2.delivered().count == 1 }
        guard case .failure(.modelUnavailable) = await host2.delivered()[0].outcome else {
            Issue.record("expected modelUnavailable")
            return
        }
        #expect(await provider.startedPrompts().isEmpty)
    }

    @Test func subscribeYieldsCurrentSnapshotFirstThenChanges() async throws {
        let provider = FakeProvider(outcomes: [.success(okResult())])
        let (queue, _) = try makeQueue(provider)
        let item = makeItem()
        await queue.enqueue(item)
        await eventually("started") { await provider.startedPrompts().count == 1 }

        var iterator = await queue.subscribe().makeAsyncIterator()
        let first = try #require(await iterator.next())
        #expect(first.entries.map(\.id) == [item.id])
        #expect({ if case .running = first.entries[0].state { true } else { false } }())

        await provider.release()
        var sawEmpty = false
        while let snapshot = await iterator.next() {
            if snapshot.entries.isEmpty { sawEmpty = true; break }
        }
        #expect(sawEmpty)

        // A second subscriber gets its own stream starting from the current (empty) snapshot.
        var other = await queue.subscribe().makeAsyncIterator()
        #expect(try #require(await other.next()).entries.isEmpty)
    }
}
