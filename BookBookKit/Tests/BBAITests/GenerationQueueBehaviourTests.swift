import BBAICore
import BBModel
import Foundation
import Testing
@testable import BBAI

/// Phase 9 queue state machine (A §7.9, §7.10): ordering, cancel, retry, timeout, pause,
/// persistence, ledger and redelivery.
@Suite struct GenerationQueueBehaviourTests {
    let book = SliceBook.make()
    static let start = Date(timeIntervalSince1970: 100)
    static let estimate = CostEstimate(amount: Decimal(string: "0.04")!, priceListAsOf: "2026-11-01")

    struct Harness {
        var queue: GenerationQueue
        var host: FakeHost
        var provider: FakeProvider
        var sleep: FakeSleep
        var persistence: FakePersistence?
    }

    func make(_ outcomes: [Result<ImageResult, ProviderError>], gated: Bool = false, host: FakeHost? = nil,
              sleep: FakeSleep = FakeSleep(), persistence: FakePersistence? = nil, pricing: any CostPricing = FakePricing(),
              catalog: ModelCatalog? = nil, timeout: Duration = .seconds(300)) throws -> Harness {
        let provider = FakeProvider(outcomes: outcomes, gated: gated)
        let host = host ?? FakeHost(content: book.content)
        let queue = GenerationQueue(providers: [.openai: provider], catalog: try catalog ?? ModelCatalog.bundled(),
                                    host: host, pricing: pricing, persistence: persistence,
                                    now: { Self.start }, sleep: sleep.closure, jitter: { 0.5 }, requestTimeout: timeout)
        return Harness(queue: queue, host: host, provider: provider, sleep: sleep, persistence: persistence)
    }

    func item(_ message: String) -> QueueItem {
        QueueItem(bookID: book.content.book.id, target: book.target, messageID: MessageID(), intent: intent(message),
                  estimate: Self.estimate)
    }

    func waitingIDs(_ queue: GenerationQueue) async -> [QueueItemID] {
        await queue.snapshot().entries.filter { $0.state == .waiting }.map(\.id)
    }

    // MARK: Ordering

    @Test func batchEnqueueAndFrontPosition() async throws {
        let h = try make(Array(repeating: .success(okResult()), count: 4), gated: true)
        let a = item("aaa"), b = item("bbb"), c = item("ccc"), d = item("ddd")
        await h.queue.enqueue(a)
        await eventually("a started") { await h.provider.startedPrompts().count == 1 }
        let ids = await h.queue.enqueue([b, c])
        #expect(ids == [b.id, c.id])
        await h.queue.enqueue([d], position: .front)
        #expect(await h.queue.snapshot().entries.map(\.id) == [a.id, d.id, b.id, c.id])
        // Re-enqueueing a known ID is ignored.
        #expect(await h.queue.enqueue([b]).isEmpty)
        await h.provider.release(4)
        await eventually("all delivered") { await h.host.delivered().count == 4 }
        let prompts = await h.provider.startedPrompts()
        #expect(["aaa", "ddd", "bbb", "ccc"].enumerated().allSatisfy { prompts[$0.offset].contains($0.element) })
    }

    @Test func moveReordersWaitingItemsOnly() async throws {
        let h = try make(Array(repeating: .success(okResult()), count: 4), gated: true)
        let a = item("aaa"), b = item("bbb"), c = item("ccc"), d = item("ddd")
        await h.queue.enqueue([a, b, c, d])
        await eventually("a started") { await h.provider.startedPrompts().count == 1 }
        await h.queue.move(d.id, to: 1)
        await h.queue.move(a.id, to: 3)   // running: ignored
        await h.queue.move(b.id, to: 99)  // clamped to the end
        #expect(await h.queue.snapshot().entries.map(\.id) == [a.id, d.id, c.id, b.id])
        await h.provider.release(4)
        await eventually("all delivered") { await h.host.delivered().count == 4 }
        #expect(await h.host.delivered().map(\.item.id) == [a.id, d.id, c.id, b.id])
    }

    @Test func removeWaitingDeliversCancelledAndRemoveFailedDoesNot() async throws {
        let h = try make([.failure(.refused(stage: .input, categories: [], nil)), .success(okResult())], gated: true)
        let a = item("aaa"), b = item("bbb")
        await h.queue.enqueue([a, b])
        await eventually("a started") { await h.provider.startedPrompts().count == 1 }
        await h.queue.remove(b.id)
        #expect(await h.queue.snapshot().entry(for: b.id) == nil)
        let removed = try #require(await h.host.delivered().first)
        #expect(removed.item.id == b.id)
        guard case .failure(.cancelled) = removed.outcome else { Issue.record("expected cancelled"); return }

        await h.provider.release()
        await eventually("a failed") { await h.queue.snapshot().entry(for: a.id)?.failure != nil }
        #expect(await h.host.delivered().count == 2)
        await h.queue.remove(a.id)
        #expect(await h.queue.snapshot().entries.isEmpty)
        #expect(await h.host.delivered().count == 2)
        // Nothing removed reached the provider.
        #expect(await h.provider.startedPrompts().count == 1)
    }

    // MARK: Cancel

    @Test func cancelRunningRecordsEstimateDeliversAndStartsNext() async throws {
        let h = try make([.success(okResult()), .success(okResult())], gated: true)
        let a = item("aaa"), b = item("bbb")
        await h.queue.enqueue([a, b])
        await eventually("a started") { await h.provider.startedPrompts().count == 1 }
        await h.queue.cancelRunning()
        await eventually("b started") { await h.provider.startedPrompts().count == 2 }
        let cost = try #require(await h.host.recorded().first)
        #expect(cost.status == .cancelled)
        #expect(cost.basis == .estimate)
        #expect(cost.estimated == Self.estimate.amount)
        #expect(cost.amount == Self.estimate.amount)
        #expect(cost.actual == nil)
        #expect(cost.queueItemID == a.id)
        #expect(cost.priceListAsOf == "2026-11-01")
        #expect(await h.host.log().prefix(4) == ["content", "cost:cancelled", "deliver:failure", "content"])
        guard case .failure(.cancelled) = try #require(await h.host.delivered().first).outcome else {
            Issue.record("expected cancelled")
            return
        }
        #expect(await h.queue.snapshot().entry(for: a.id) == nil)
        await h.provider.release(2)
        await eventually("b delivered") { await h.host.delivered().count == 2 }
    }

    // MARK: Retry

    @Test func transientErrorsRetryWithBackoffThenFail() async throws {
        let raw = ProviderErrorRaw(status: 503, code: nil, body: "overloaded")
        let h = try make(Array(repeating: .failure(.transient(raw)), count: 5))
        let a = item("aaa")
        await h.queue.enqueue(a)
        await eventually("failed") { await h.queue.snapshot().entry(for: a.id)?.failure != nil }
        #expect(await h.provider.startedPrompts().count == 4)
        // base 2 s ×2 per retry, plus jitter (0.5) · base.
        #expect(await h.sleep.recorded() == [.seconds(3), .seconds(5), .seconds(9)])
        let failure = try #require(await h.queue.snapshot().entry(for: a.id)?.failure)
        #expect(failure.attempts == 4)
        #expect(failure.error == .transient(raw))
        #expect(failure.report?.promptText.contains("aaa") == true)
        #expect(failure.failedAt == Self.start)
        // One ledger line per request (5xx: $0), one failure delivery at the end.
        let costs = await h.host.recorded()
        #expect(costs.count == 4)
        #expect(costs.allSatisfy { $0.status == .failed && $0.actual == 0 && $0.basis == .actual && $0.amount == 0 })
        #expect(await h.host.delivered().count == 1)
    }

    @Test func retryAfterIsHonouredAndCapped() async throws {
        let h = try make([.failure(.rateLimited(retryAfter: 7, nil)), .failure(.rateLimited(retryAfter: 500, nil)),
                          .success(okResult())])
        let a = item("aaa")
        await h.queue.enqueue(a)
        await eventually("delivered") { await h.host.delivered().count == 1 }
        #expect(await h.sleep.recorded() == [.seconds(7), .seconds(120)])
        guard case .success = try #require(await h.host.delivered().first).outcome else {
            Issue.record("expected success")
            return
        }
        #expect(await h.host.recorded().map(\.status) == [.failed, .failed, .completed])
    }

    @Test func retryingStateIsPublishedWhileWaiting() async throws {
        let sleep = FakeSleep(holdFrom: .zero)
        let h = try make([.failure(.transient(nil)), .success(okResult())], sleep: sleep)
        let a = item("aaa")
        await h.queue.enqueue(a)
        await eventually("waiting out backoff") { await sleep.heldCount() == 1 }
        #expect(await h.queue.snapshot().entry(for: a.id)?.state
                == .retrying(attempt: 2, resumesAt: Self.start.addingTimeInterval(3), lastError: .transient(nil)))
        // Transport failure without a status: the estimate is recorded.
        let cost = try #require(await h.host.recorded().first)
        #expect(cost.basis == .estimate && cost.status == .failed && cost.estimated == Self.estimate.amount)
        await sleep.releaseAll()
        await eventually("delivered") { await h.host.delivered().count == 1 }
        #expect(await h.provider.startedPrompts().count == 2)
    }

    @Test func noImageRetriesOnce() async throws {
        let h = try make([.failure(.noImage(nil)), .failure(.noImage(nil)), .success(okResult())])
        let a = item("aaa")
        await h.queue.enqueue(a)
        await eventually("failed") { await h.queue.snapshot().entry(for: a.id)?.failure != nil }
        #expect(await h.provider.startedPrompts().count == 2)
        #expect(await h.sleep.recorded().count == 1)
        #expect(await h.queue.snapshot().entry(for: a.id)?.failure?.attempts == 2)
    }

    @Test func nonTransientFailsAtOnceAndManualRetryRequeues() async throws {
        let h = try make([.failure(.invalidRequest(param: "size", nil)), .success(okResult())])
        let a = item("aaa")
        await h.queue.enqueue(a)
        await eventually("failed") { await h.queue.snapshot().entry(for: a.id)?.failure != nil }
        #expect(await h.sleep.recorded().isEmpty)
        #expect(await h.provider.startedPrompts().count == 1)
        await h.queue.retry(a.id)
        await eventually("delivered") { await h.host.delivered().count == 2 }
        guard case .success = await h.host.delivered()[1].outcome else { Issue.record("expected success"); return }
        #expect(await h.queue.snapshot().entries.isEmpty)
    }

    @Test func removingARetryingItemCancelsItWithoutAnotherLedgerLine() async throws {
        let sleep = FakeSleep(holdFrom: .zero)
        let h = try make([.failure(.transient(nil)), .success(okResult())], sleep: sleep)
        let a = item("aaa")
        await h.queue.enqueue(a)
        await eventually("retrying") { await sleep.heldCount() == 1 }
        await h.queue.remove(a.id)
        await eventually("removed") { await h.queue.snapshot().entries.isEmpty }
        await eventually("cancel delivered") { await h.host.delivered().count == 1 }
        guard case .failure(.cancelled) = await h.host.delivered()[0].outcome else {
            Issue.record("expected cancelled")
            return
        }
        #expect(await h.host.recorded().count == 1)
        #expect(await h.provider.startedPrompts().count == 1)
    }

    // MARK: Timeout

    @Test func requestTimesOutAndIsNotRetried() async throws {
        let h = try make([.success(okResult()), .success(okResult())], gated: true, timeout: .milliseconds(50))
        let a = item("aaa")
        await h.queue.enqueue(a)
        await eventually("failed") { await h.queue.snapshot().entry(for: a.id)?.failure != nil }
        #expect(await h.queue.snapshot().entry(for: a.id)?.failure?.error == .timeout)
        #expect(await h.provider.startedPrompts().count == 1)
        let cost = try #require(await h.host.recorded().first)
        #expect(cost.status == .failed && cost.basis == .estimate && cost.amount == Self.estimate.amount)
        guard case .failure(.timeout) = try #require(await h.host.delivered().first).outcome else {
            Issue.record("expected timeout")
            return
        }
    }

    // MARK: Pause

    @Test func offlineAndUserPause() async throws {
        let h = try make([.success(okResult()), .success(okResult())])
        await h.queue.setOnline(false)
        await h.queue.pause()
        #expect(await h.queue.snapshot().pause == .offline)
        let a = item("aaa")
        await h.queue.enqueue(a)
        try await Task.sleep(for: .milliseconds(30))
        #expect(await h.provider.startedPrompts().isEmpty)
        await h.queue.setOnline(true)
        #expect(await h.queue.snapshot().pause == .user)
        try await Task.sleep(for: .milliseconds(30))
        #expect(await h.provider.startedPrompts().isEmpty)
        await h.queue.resume()
        #expect(await h.queue.snapshot().pause == nil)
        await eventually("delivered") { await h.host.delivered().count == 1 }
    }

    @Test func pauseLetsTheRunningItemFinish() async throws {
        let h = try make([.success(okResult()), .success(okResult())], gated: true)
        let a = item("aaa"), b = item("bbb")
        await h.queue.enqueue([a, b])
        await eventually("a started") { await h.provider.startedPrompts().count == 1 }
        await h.queue.pause()
        await h.provider.release(2)
        await eventually("a delivered") { await h.host.delivered().count == 1 }
        try await Task.sleep(for: .milliseconds(30))
        #expect(await h.provider.startedPrompts().count == 1)
        #expect(await waitingIDs(h.queue) == [b.id])
        await h.queue.resume()
        await eventually("b delivered") { await h.host.delivered().count == 2 }
    }

    @Test func offlineDuringRetryWaitWaitsForOnline() async throws {
        let sleep = FakeSleep(holdFrom: .zero)
        let h = try make([.failure(.offline), .success(okResult())], sleep: sleep)
        let a = item("aaa")
        await h.queue.enqueue(a)
        await eventually("retrying") { await sleep.heldCount() == 1 }
        await h.queue.setOnline(false)
        await sleep.releaseAll()
        try await Task.sleep(for: .milliseconds(30))
        #expect(await h.provider.startedPrompts().count == 1)
        await h.queue.setOnline(true)
        await eventually("delivered") { await h.host.delivered().count == 1 }
        #expect(await h.provider.startedPrompts().count == 2)
    }

    // MARK: Persistence

    @Test func everyChangeIsSavedWithRunningAndFailedState() async throws {
        let persistence = FakePersistence()
        let h = try make([.failure(.refused(stage: .output, categories: [], nil)), .success(okResult())], gated: true,
                         persistence: persistence)
        let a = item("aaa"), b = item("bbb")
        await h.queue.enqueue([a, b])
        await eventually("a in flight saved") { await persistence.last()?.entries.first?.wasRunning == true }
        #expect(await persistence.last()?.entries.map(\.item.id) == [a.id, b.id])
        #expect(await persistence.last()?.entries[1].wasRunning == false)
        await h.provider.release()
        await eventually("a failed saved") { await persistence.last()?.entries.first?.failure != nil }
        await eventually("b in flight saved") { await persistence.last()?.entries.last?.wasRunning == true }
        await h.provider.release()
        await eventually("b done saved") { await persistence.last()?.entries.count == 1 }
        let saved = try #require(await persistence.last())
        #expect(saved.entries[0].item == a)
        #expect(saved.entries[0].failure?.error == .refused(stage: .output, categories: [], nil))
        #expect(saved.schemaVersion == PersistedQueue.currentSchemaVersion)
    }

    @Test func retryingItemsPersistAsWaiting() async throws {
        let sleep = FakeSleep(holdFrom: .zero)
        let persistence = FakePersistence()
        let h = try make([.failure(.transient(nil))], sleep: sleep, persistence: persistence)
        let a = item("aaa")
        await h.queue.enqueue(a)
        await eventually("retrying") { await sleep.heldCount() == 1 }
        await eventually("saved as waiting") {
            guard let entry = await persistence.last()?.entries.first else { return false }
            return !entry.wasRunning && entry.failure == nil
        }
    }

    @Test func restoreBringsBackWaitingAndFailedPausedAndCancelsInterrupted() async throws {
        let running = item("running"), waiting = item("waiting"), failed = item("failed")
        let failure = QueueFailure(error: .refused(stage: .input, categories: ["x"], nil), report: nil, attempts: 1,
                                   failedAt: Self.start)
        let persistence = FakePersistence(initial: PersistedQueue(entries: [
            .init(item: running, wasRunning: true), .init(item: waiting), .init(item: failed, failure: failure),
        ]))
        let h = try make([.success(okResult())], persistence: persistence)
        await h.queue.restore()
        let snapshot = await h.queue.snapshot()
        #expect(snapshot.entries.map(\.id) == [waiting.id, failed.id])
        #expect(snapshot.entry(for: waiting.id)?.state == .waiting)
        #expect(snapshot.entry(for: failed.id)?.failure == failure)
        #expect(snapshot.pause == .restored(count: 1))
        // The interrupted item: estimated cancelled ledger line, then its message is cleared.
        let cost = try #require(await h.host.recorded().first)
        #expect(cost.status == .cancelled && cost.basis == .estimate && cost.queueItemID == running.id)
        #expect(cost.model == running.intent.model)
        let delivery = try #require(await h.host.delivered().first)
        #expect(delivery.item.id == running.id)
        guard case .failure(.cancelled) = delivery.outcome else { Issue.record("expected cancelled"); return }
        #expect(await h.host.log() == ["cost:cancelled", "deliver:failure"])
        try await Task.sleep(for: .milliseconds(30))
        #expect(await h.provider.startedPrompts().isEmpty)

        await h.queue.restore()  // runs once
        #expect(await h.host.recorded().count == 1)

        await h.queue.resume()
        #expect(await h.queue.snapshot().pause == nil)
        await eventually("waiting delivered") { await h.host.delivered().count == 2 }
        #expect(await h.host.delivered()[1].item.id == waiting.id)
    }

    @Test func restoreWithNothingSavedLeavesQueueRunning() async throws {
        let h = try make([.success(okResult())], persistence: FakePersistence())
        await h.queue.restore()
        #expect(await h.queue.snapshot().pause == nil)
        await h.queue.enqueue(item("aaa"))
        await eventually("delivered") { await h.host.delivered().count == 1 }
    }

    // MARK: Ledger

    @Test func successWithUsageIsPricedActualAndProvenanceCarriesCostID() async throws {
        let h = try make([.success(okResult())])
        await h.queue.enqueue(item("aaa"))
        await eventually("delivered") { await h.host.delivered().count == 1 }
        let cost = try #require(await h.host.recorded().first)
        #expect(cost.status == .completed && cost.basis == .actual)
        #expect(cost.actual == Decimal(string: "0.012"))
        #expect(cost.estimated == Self.estimate.amount)
        #expect(cost.priceListAsOf == "2026-11-07")
        #expect(cost.kind == .image && cost.quality == .draft && cost.target == book.target)
        let delivery = try #require(await h.host.delivered().first)
        #expect(delivery.costRecordID == cost.id)
        guard case let .success(_, provenance) = delivery.outcome else { Issue.record("expected success"); return }
        #expect(provenance.cost == cost.id)
        #expect(await h.host.log() == ["content", "cost:completed", "deliver:success"])
    }

    @Test func successWithoutUsageOrPriceRecordsTheEstimate() async throws {
        var noUsage = okResult()
        noUsage.usage = nil
        let h = try make([.success(noUsage), .success(okResult())], pricing: FakePricing(prices: [:]))
        var unknown = item("aaa")
        unknown.estimate = .unknown
        await h.queue.enqueue([unknown, item("bbb")])
        await eventually("delivered") { await h.host.delivered().count == 2 }
        let costs = await h.host.recorded()
        #expect(costs[0].basis == .estimate && costs[0].estimated == 0 && costs[0].actual == nil)
        #expect(costs[1].basis == .estimate && costs[1].estimated == Self.estimate.amount)
    }

    @Test func customModelIsPricedThroughItsPricingModel() async throws {
        var catalog = try ModelCatalog.bundled()
        var custom = try #require(catalog.imageModel(provider: .openai, id: "gpt-image-2.5-sunburst"))
        custom.id = "my-custom-image"
        custom.copiesFrom = "gpt-image-2.5-sunburst"
        catalog.imageModels.append(custom)
        let h = try make([.success(okResult())], catalog: catalog)
        var custom1 = item("aaa")
        custom1.intent.model = "my-custom-image"
        await h.queue.enqueue(custom1)
        await eventually("delivered") { await h.host.delivered().count == 1 }
        let cost = try #require(await h.host.recorded().first)
        #expect(cost.model == "my-custom-image")
        #expect(cost.basis == .actual && cost.actual == Decimal(string: "0.012"))
    }

    @Test func failuresBeforeAnyRequestWriteNoLedgerLine() async throws {
        let h = try make([.failure(.missingKey)])
        let a = item("aaa")
        await h.queue.enqueue(a)
        await eventually("failed") { await h.queue.snapshot().entry(for: a.id)?.failure != nil }
        var badModel = item("bbb")
        badModel.intent.model = "nope"
        await h.queue.enqueue(badModel)
        let badID = badModel.id
        await eventually("failed 2") { await h.queue.snapshot().entry(for: badID)?.failure != nil }
        #expect(await h.queue.snapshot().entry(for: badID)?.failure?.attempts == 0)
        #expect(await h.host.recorded().isEmpty)
        #expect(await h.host.delivered().count == 2)
    }

    @Test(arguments: [
        (ProviderError.missingKey, QueueLedgerRule.none),
        (.cancelled, .estimate(.cancelled)),
        (.timeout, .estimate(.failed)),
        (.offline, .none),
        (.transient(nil), .estimate(.failed)),
        (.transient(ProviderErrorRaw(status: 500, code: nil, body: "")), .free),
        (.noImage(ProviderErrorRaw(status: 200, code: nil, body: "")), .estimate(.failed)),
        (.unknown(ProviderErrorRaw(status: 418, code: nil, body: "")), .free),
        (.unknown(nil), .estimate(.failed)),
        (.invalidKey(nil), .free),
        (.rateLimited(retryAfter: 3, nil), .free),
        (.refused(stage: .input, categories: [], nil), .free),
        (.billing(nil), .free),
        (.invalidRequest(param: "size", nil), .free),
        (.modelUnavailable(nil), .free),
        (.verificationRequired(nil), .free),
        (.regionUnsupported(nil), .free),
    ])
    func ledgerRuleForEachFailure(error: ProviderError, rule: QueueLedgerRule) {
        #expect(QueueLedgerRule.forFailure(error) == rule)
    }

    // MARK: Delivery

    @Test func bookUnavailableDeliveryIsKeptAndRedelivered() async throws {
        let sleep = FakeSleep(holdFrom: GenerationQueue.redeliveryInterval)
        let host = FakeHost(content: book.content, deliveryResults: [.bookUnavailable, .bookUnavailable])
        let h = try make([.success(okResult())], host: host, sleep: sleep)
        await h.queue.enqueue(item("aaa"))
        await eventually("kept") { await h.queue.snapshot().undeliveredCount == 1 }
        #expect(await h.queue.snapshot().entries.isEmpty)
        // The 30 s timer fires: still locked.
        await eventually("timer armed") { await sleep.heldCount() == 1 }
        await sleep.releaseAll()
        await eventually("second attempt") { await host.attempts() == 2 }
        #expect(await h.queue.snapshot().undeliveredCount == 1)
        // A queue change retries at once (no timer release needed).
        await eventually("timer re-armed") { await sleep.heldCount() == 1 }
        await h.queue.pause()
        await eventually("delivered") { await host.delivered().count == 1 }
        await eventually("count cleared") { await h.queue.snapshot().undeliveredCount == 0 }
        #expect(await sleep.recorded().allSatisfy { $0 == GenerationQueue.redeliveryInterval })
        #expect(await host.recorded().count == 1)
    }

    @Test func bookGoneDeliveryIsDropped() async throws {
        let sleep = FakeSleep(holdFrom: .zero)
        let host = FakeHost(content: book.content, deliveryResults: [.bookGone])
        let h = try make([.success(okResult())], host: host, sleep: sleep)
        await h.queue.enqueue(item("aaa"))
        await eventually("attempted") { await host.attempts() == 1 }
        try await Task.sleep(for: .milliseconds(30))
        #expect(await h.queue.snapshot().undeliveredCount == 0)
        #expect(await host.attempts() == 1)
        #expect(await sleep.recorded().isEmpty)
    }

    // MARK: Races

    @Test func slowProviderEditsWhileRunningDoNotInterleave() async throws {
        let h = try make(Array(repeating: .success(okResult()), count: 3), gated: true)
        let a = item("aaa"), b = item("bbb"), c = item("ccc")
        await h.queue.enqueue([a, b, c])
        await eventually("a started") { await h.provider.startedPrompts().count == 1 }
        // While A is in flight: the style changes, C is removed, and the queue is edited.
        var edited = book.content
        edited.style.visualDescription = "Bold ink lines."
        await h.host.setContent(edited)
        await h.queue.remove(c.id)
        await h.queue.remove(a.id)  // in flight: ignored
        await h.queue.move(b.id, to: 0)
        #expect(await h.provider.startedPrompts().count == 1)
        await h.provider.release()
        await eventually("b started") { await h.provider.startedPrompts().count == 2 }
        let prompts = await h.provider.startedPrompts()
        #expect(!prompts[0].contains("Bold ink lines.") && prompts[1].contains("Bold ink lines."))
        // A's delivery lands before B reads the book; C's cancellation came first of all.
        #expect(await h.host.log() == ["content", "deliver:failure", "cost:completed", "deliver:success", "content"])
        await h.provider.release()
        await eventually("b delivered") { await h.host.delivered().count == 3 }
        #expect(await h.host.delivered().map(\.item.id) == [c.id, a.id, b.id])
    }

    // MARK: Policy

    @Test func retryPolicyDelays() {
        let policy = QueueRetryPolicy.standard
        #expect(policy.delay(after: .transient(nil), retriesSoFar: 0, jitter: 0) == .seconds(2))
        #expect(policy.delay(after: .transient(nil), retriesSoFar: 1, jitter: 1) == .seconds(6))
        #expect(policy.delay(after: .offline, retriesSoFar: 2, jitter: 0) == .seconds(8))
        #expect(policy.delay(after: .offline, retriesSoFar: 3, jitter: 0) == nil)
        #expect(policy.delay(after: .rateLimited(retryAfter: 1.5, nil), retriesSoFar: 0, jitter: 1) == .seconds(1.5))
        #expect(policy.delay(after: .rateLimited(retryAfter: 999, nil), retriesSoFar: 2, jitter: 0) == .seconds(120))
        #expect(policy.delay(after: .noImage(nil), retriesSoFar: 0, jitter: 0) == .seconds(2))
        #expect(policy.delay(after: .noImage(nil), retriesSoFar: 1, jitter: 0) == nil)
        #expect(policy.delay(after: .timeout, retriesSoFar: 0, jitter: 0) == nil)
        #expect(policy.delay(after: .refused(stage: .input, categories: [], nil), retriesSoFar: 0, jitter: 0) == nil)
    }
}
