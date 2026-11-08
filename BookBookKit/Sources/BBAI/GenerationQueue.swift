import BBAICore
import BBModel
import Foundation

/// The app-wide serial generation queue (A §7.9).
///
/// - One item runs at a time, in order. While paused (restored, offline or by the user) nothing
///   new starts; a request already in flight finishes.
/// - Intent is fixed at enqueue time; context and image bytes are read from the host when the
///   item starts, and the same request is reused for automatic retries.
/// - Automatic retries follow `QueueRetryPolicy`; each request is raced against `requestTimeout`.
/// - One ledger line per provider request (`GenerationHost.recordCost`), always before the
///   delivery it belongs to (A §7.10).
/// - Every change is published to subscribers and saved through `QueuePersistence`.
public actor GenerationQueue {
    private let providers: [ProviderID: any ImageProvider]
    private var catalog: ModelCatalog
    private let host: any GenerationHost
    private var pricing: any CostPricing
    private let persistence: (any QueuePersistence)?
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void
    private let jitter: @Sendable () -> Double
    private let requestTimeout: Duration
    private let retryPolicy = QueueRetryPolicy.standard

    private var entries: [QueueEntry] = []
    private var current: Current?
    private var userPaused = false
    private var restoredCount: Int?
    private var online = true
    private var hasRestored = false
    /// The run task waits here (after a retry backoff) while the queue is paused.
    private var unpauseWaiter: CheckedContinuation<Void, Never>?

    private var undelivered: [PendingDelivery] = []
    private var redeliveryWorker: Task<Void, Never>?
    /// The worker's current 30 s wait; cancelled to wake it early when the queue changes.
    private var redeliveryWait: Task<Void, Never>?

    private var saving = false
    private var saveDirty = false

    private var subscribers: [UUID: AsyncStream<QueueSnapshot>.Continuation] = [:]

    /// The item the run task owns (running or waiting out a retry).
    private struct Current {
        var id: QueueItemID
        var task: Task<Void, Never>?
        var cancelRequested = false
        /// A provider request is in flight (persisted as `wasRunning`).
        var inFlight = false
    }

    private struct PendingDelivery {
        var token = UUID()
        var delivery: GenerationDelivery
    }

    public static let redeliveryInterval: Duration = .seconds(30)

    public init(providers: [ProviderID: any ImageProvider], catalog: ModelCatalog, host: any GenerationHost,
                pricing: any CostPricing, persistence: (any QueuePersistence)? = nil,
                now: @escaping @Sendable () -> Date = { Date() },
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                jitter: @escaping @Sendable () -> Double = { Double.random(in: 0...1) },
                requestTimeout: Duration = .seconds(300)) {
        self.providers = providers
        self.catalog = catalog
        self.host = host
        self.pricing = pricing
        self.persistence = persistence
        self.now = now
        self.sleep = sleep
        self.jitter = jitter
        self.requestTimeout = requestTimeout
    }

    // MARK: - Public API

    /// Loads `queue.json`. Waiting and failed items come back (the queue is then paused with
    /// `.restored(count:)`, counting waiting items); an item that was running is recorded as
    /// cancelled (estimated ledger line) and its message cleared, not re-queued. Runs once.
    public func restore() async {
        guard !hasRestored else { return }
        hasRestored = true
        guard let persistence, let saved = await persistence.load() else { return }
        var restored: [QueueEntry] = []
        var interrupted: [QueueItem] = []
        let known = Set(entries.map(\.id))
        for entry in saved.entries where !known.contains(entry.item.id) {
            if entry.wasRunning {
                interrupted.append(entry.item)
            } else if let failure = entry.failure {
                restored.append(QueueEntry(item: entry.item, state: .failed(failure)))
            } else {
                restored.append(QueueEntry(item: entry.item, state: .waiting))
            }
        }
        let waiting = restored.filter { $0.state == .waiting }.count
        if waiting > 0 { restoredCount = waiting }
        entries.insert(contentsOf: restored, at: 0)
        changed()
        for item in interrupted {
            await recordCost(for: item, model: item.intent.model, status: .cancelled, basis: .estimate, actual: nil)
            await deliver(GenerationDelivery(item: item, outcome: .failure(.cancelled)))
        }
        startNextIfIdle()
    }

    /// Adds items (in order) at the end, or before every waiting item. Returns their IDs.
    @discardableResult
    public func enqueue(_ items: [QueueItem], position: QueuePosition = .end) -> [QueueItemID] {
        let known = Set(entries.map(\.id))
        let fresh = items.filter { !known.contains($0.id) }
        let new = fresh.map { QueueEntry(item: $0, state: .waiting) }
        switch position {
        case .end:
            entries.append(contentsOf: new)
        case .front:
            let index = entries.firstIndex { $0.state == .waiting && $0.id != current?.id } ?? entries.endIndex
            entries.insert(contentsOf: new, at: index)
        }
        changed()
        startNextIfIdle()
        return fresh.map(\.id)
    }

    public func enqueue(_ item: QueueItem) {
        enqueue([item], position: .end)
    }

    /// Moves a waiting item to `index` among all entries (clamped).
    public func move(_ id: QueueItemID, to index: Int) {
        guard let from = entries.firstIndex(where: { $0.id == id }), entries[from].state == .waiting,
              id != current?.id else { return }
        let entry = entries.remove(at: from)
        entries.insert(entry, at: min(max(index, 0), entries.endIndex))
        changed()
    }

    /// Removes a waiting, retrying or failed item. A waiting or retrying item's message is
    /// cleared with a `.failure(.cancelled)` delivery (a failed item's was cleared when it
    /// failed). Does nothing while the item's request is in flight; use `cancelRunning()`.
    public func remove(_ id: QueueItemID) async {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        switch entries[index].state {
        case .running:
            return
        case .retrying:
            cancelCurrent()
        case .failed:
            entries.remove(at: index)
            changed()
        case .waiting:
            let item = entries.remove(at: index).item
            changed()
            await deliver(GenerationDelivery(item: item, outcome: .failure(.cancelled)))
        }
    }

    /// Cancels the running (or retrying) item: the provider call is cancelled, an estimated
    /// `.cancelled` ledger line is written if a request was in flight, the item is removed and
    /// its delivery is `.failure(.cancelled)`. The next item then starts.
    public func cancelRunning() {
        cancelCurrent()
    }

    /// Puts a failed item back at the end of the queue.
    public func retry(_ id: QueueItemID) {
        guard let index = entries.firstIndex(where: { $0.id == id }),
              case .failed = entries[index].state else { return }
        var entry = entries.remove(at: index)
        entry.state = .waiting
        entries.append(entry)
        changed()
        startNextIfIdle()
    }

    public func pause() {
        guard !userPaused else { return }
        userPaused = true
        changed()
    }

    /// Clears a user pause and the restored-at-launch pause. An offline pause stays until online.
    public func resume() {
        guard userPaused || restoredCount != nil else { return }
        userPaused = false
        restoredCount = nil
        changed()
        pauseMayHaveCleared()
    }

    /// Driven by `NWPathMonitor`. Offline pauses the queue; online clears that and restarts it.
    public func setOnline(_ isOnline: Bool) {
        guard online != isOnline else { return }
        online = isOnline
        changed()
        pauseMayHaveCleared()
    }

    /// Used from the next item that starts.
    public func setCatalog(_ catalog: ModelCatalog) { self.catalog = catalog }

    /// Used for the next ledger line.
    public func setPricing(_ pricing: any CostPricing) { self.pricing = pricing }

    public func snapshot() -> QueueSnapshot {
        QueueSnapshot(entries: entries, pause: pauseReason, undeliveredCount: undelivered.count)
    }

    /// A new stream per subscriber. Yields the current snapshot first, then every change.
    public func subscribe() -> AsyncStream<QueueSnapshot> {
        let (stream, continuation) = AsyncStream.makeStream(of: QueueSnapshot.self, bufferingPolicy: .bufferingNewest(1))
        let token = UUID()
        subscribers[token] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(token) }
        }
        continuation.yield(snapshot())
        return stream
    }

    // MARK: - State

    private var pauseReason: QueuePause? {
        if !online { return .offline }
        if let restoredCount { return .restored(count: restoredCount) }
        if userPaused { return .user }
        return nil
    }

    private func removeSubscriber(_ token: UUID) {
        subscribers[token] = nil
    }

    private func publish() {
        let current = snapshot()
        for continuation in subscribers.values { continuation.yield(current) }
    }

    /// Every queue change: publish, save, and wake the redelivery worker.
    private func changed() {
        publish()
        persist()
        redeliveryWait?.cancel()
    }

    private func pauseMayHaveCleared() {
        guard pauseReason == nil else { return }
        unpauseWaiter?.resume()
        unpauseWaiter = nil
        startNextIfIdle()
    }

    private func setState(_ id: QueueItemID, _ state: QueueItemState) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].state = state
        changed()
    }

    private func isCancelled(_ id: QueueItemID) -> Bool {
        current?.id == id && current?.cancelRequested == true
    }

    private func cancelCurrent() {
        guard current != nil, current?.cancelRequested == false else { return }
        current?.cancelRequested = true
        current?.task?.cancel()
        unpauseWaiter?.resume()
        unpauseWaiter = nil
    }

    // MARK: - Persistence

    private func persistedQueue() -> PersistedQueue {
        PersistedQueue(entries: entries.map { entry in
            switch entry.state {
            case .waiting, .retrying:
                return PersistedQueue.Entry(item: entry.item)
            case .running:
                return PersistedQueue.Entry(item: entry.item, wasRunning: current?.id == entry.id && current?.inFlight == true)
            case let .failed(failure):
                return PersistedQueue.Entry(item: entry.item, failure: failure)
            }
        })
    }

    /// Coalesced: at most one save in flight; the last one always writes the latest state.
    private func persist() {
        guard persistence != nil else { return }
        saveDirty = true
        guard !saving else { return }
        saving = true
        Task { await self.drainSaves() }
    }

    private func drainSaves() async {
        guard let persistence else { return }
        while saveDirty {
            saveDirty = false
            await persistence.save(persistedQueue())
        }
        saving = false
    }

    // MARK: - Running

    private func startNextIfIdle() {
        guard current == nil, pauseReason == nil,
              let index = entries.firstIndex(where: { $0.state == .waiting }) else { return }
        let item = entries[index].item
        current = Current(id: item.id)
        entries[index].state = .running(startedAt: now(), progress: nil, attempt: 1)
        changed()
        current?.task = Task { [weak self] in
            await self?.run(item)
            await self?.finishRunning(item.id)
        }
    }

    private func finishRunning(_ id: QueueItemID) {
        guard current?.id == id else { return }
        current = nil
        startNextIfIdle()
    }

    private func updateProgress(_ id: QueueItemID, attempt: Int, _ progress: GenerationProgress) {
        guard let index = entries.firstIndex(where: { $0.id == id }),
              case let .running(startedAt, _, running) = entries[index].state, running == attempt else { return }
        entries[index].state = .running(startedAt: startedAt, progress: progress, attempt: attempt)
        // Progress is display-only: publish without saving or waking redelivery.
        publish()
    }

    private func run(_ item: QueueItem) async {
        guard let (provider, model, request, report) = await prepare(item) else { return }
        var attempt = 1
        while true {
            if isCancelled(item.id) { return await finishCancelled(item) }
            current?.inFlight = true
            setState(item.id, .running(startedAt: now(), progress: nil, attempt: attempt))
            let id = item.id, thisAttempt = attempt
            let outcome = await Self.race(provider, request, timeout: requestTimeout) { [weak self] progress in
                Task { await self?.updateProgress(id, attempt: thisAttempt, progress) }
            }
            current?.inFlight = false

            if isCancelled(item.id) {
                await recordCost(for: item, model: model.id, status: .cancelled, basis: .estimate, actual: nil)
                return await finishCancelled(item)
            }
            switch outcome {
            case let .success(result):
                return await finishSuccess(item, model: model, result: result, report: report)
            case let .failure(error):
                switch QueueLedgerRule.forFailure(error) {
                case .none: break
                case .free: await recordCost(for: item, model: model.id, status: .failed, basis: .actual, actual: 0)
                case let .estimate(status): await recordCost(for: item, model: model.id, status: status, basis: .estimate, actual: nil)
                }
                guard let delay = retryPolicy.delay(after: error, retriesSoFar: attempt - 1, jitter: jitter()) else {
                    return await finishFailed(item, error, report: report, attempts: attempt)
                }
                attempt += 1
                setState(item.id, .retrying(attempt: attempt, resumesAt: now().addingTimeInterval(delay.timeInterval),
                                            lastError: error))
                try? await sleep(delay)
                await waitUntilUnpaused(item.id)
            }
        }
    }

    /// Resolves the provider, model and request. On failure the item is finished and nil returned.
    private func prepare(_ item: QueueItem) async -> (any ImageProvider, CatalogModel, ImageRequest, AssemblyReport)? {
        guard let content = await host.content(for: item.bookID) else {
            await finishFailed(item, .unknown(nil), report: nil, attempts: 0)
            return nil
        }
        guard let model = catalog.imageModel(provider: item.intent.provider, id: item.intent.model) else {
            await finishFailed(item, .modelUnavailable(nil), report: nil, attempts: 0)
            return nil
        }
        guard let provider = providers[item.intent.provider] else {
            await finishFailed(item, .unknown(nil), report: nil, attempts: 0)
            return nil
        }
        guard let planned = ContextAssembler.plan(intent: item.intent, target: item.target,
                                                  messageID: item.messageID, content: content) else {
            await finishFailed(item, .unknown(nil), report: nil, attempts: 0)
            return nil
        }
        var imageData: [ImageRef: Data] = [:]
        for image in planned {
            if let data = await host.imageData(for: image.ref, in: item.bookID) { imageData[image.ref] = data }
        }
        if isCancelled(item.id) {
            await finishCancelled(item)
            return nil
        }
        do throws(AssemblyError) {
            let (request, report) = try ContextAssembler.assemble(
                intent: item.intent, target: item.target, messageID: item.messageID, content: content,
                model: model, imageData: imageData)
            return (provider, model, request, report)
        } catch {
            await finishFailed(item, error.providerError, report: nil, attempts: 0)
            return nil
        }
    }

    /// Races the provider call against the request timeout; the loser is cancelled.
    private nonisolated static func race(_ provider: any ImageProvider, _ request: ImageRequest, timeout: Duration,
                                         progress: @escaping @Sendable (GenerationProgress) -> Void)
        async -> Result<ImageResult, ProviderError> {
        await withTaskGroup(of: Result<ImageResult, ProviderError>?.self) { group in
            group.addTask {
                do throws(ProviderError) {
                    return .success(try await provider.generate(request, progress: progress))
                } catch {
                    return .failure(error)
                }
            }
            group.addTask {
                do { try await Task.sleep(for: timeout) } catch { return nil }
                return .failure(.timeout)
            }
            var outcome: Result<ImageResult, ProviderError> = .failure(.cancelled)
            for await result in group {
                if let result {
                    outcome = result
                    break
                }
            }
            group.cancelAll()
            return outcome
        }
    }

    /// After a retry backoff: waits while the queue is paused (offline, user or restored),
    /// unless the item is cancelled.
    private func waitUntilUnpaused(_ id: QueueItemID) async {
        while pauseReason != nil, !isCancelled(id) {
            await withCheckedContinuation { continuation in
                unpauseWaiter?.resume()
                unpauseWaiter = continuation
            }
        }
    }

    private func finishSuccess(_ item: QueueItem, model: CatalogModel, result: ImageResult,
                               report: AssemblyReport) async {
        let actual = result.usage.flatMap {
            pricing.actualCost(of: $0, provider: item.intent.provider, model: model.pricingModelID)
        }
        let costID = await recordCost(for: item, model: model.id, status: .completed,
                                      basis: actual == nil ? .estimate : .actual, actual: actual)
        let provenance = Provenance(
            provider: item.intent.provider, model: model.id, quality: item.intent.quality,
            outputSize: result.pixelSize, promptSent: report.promptText,
            referencesSent: report.referencesSent, referencesOmitted: report.referencesOmitted,
            styleRevision: report.styleRevision, storyTextIncluded: report.storyTextIncluded,
            intent: item.intent, cost: costID, usage: result.usage, revisedPrompt: result.revisedPrompt,
            parametersSent: result.parametersSent)
        entries.removeAll { $0.id == item.id }
        changed()
        await deliver(GenerationDelivery(item: item, outcome: .success(result: result, provenance: provenance),
                                         costRecordID: costID))
    }

    private func finishFailed(_ item: QueueItem, _ error: ProviderError, report: AssemblyReport?, attempts: Int) async {
        if isCancelled(item.id) { return await finishCancelled(item) }
        if let index = entries.firstIndex(where: { $0.id == item.id }) {
            entries[index].state = .failed(QueueFailure(error: error, report: report, attempts: attempts, failedAt: now()))
            changed()
        }
        await deliver(GenerationDelivery(item: item, outcome: .failure(error)))
    }

    /// A cancelled (or removed-while-retrying) item is not kept: the user asked for it to go.
    private func finishCancelled(_ item: QueueItem) async {
        entries.removeAll { $0.id == item.id }
        changed()
        await deliver(GenerationDelivery(item: item, outcome: .failure(.cancelled)))
    }

    // MARK: - Ledger

    @discardableResult
    private func recordCost(for item: QueueItem, model: String, status: CostStatus, basis: CostBasis,
                            actual: Decimal?) async -> CostRecordID {
        let record = CostRecord(
            at: now(), kind: .image, provider: item.intent.provider, model: model, quality: item.intent.quality,
            target: item.target, status: status, estimated: item.estimate.amount ?? 0, actual: actual, basis: basis,
            priceListAsOf: basis == .actual ? pricing.priceListAsOf : (item.estimate.priceListAsOf ?? pricing.priceListAsOf),
            queueItemID: item.id)
        await host.recordCost(record, in: item.bookID)
        return record.id
    }

    // MARK: - Delivery

    private func deliver(_ delivery: GenerationDelivery) async {
        switch await host.deliver(delivery) {
        case .delivered, .bookGone:
            break
        case .bookUnavailable:
            undelivered.append(PendingDelivery(delivery: delivery))
            changed()
            startRedeliveryWorker()
        }
    }

    private func startRedeliveryWorker() {
        guard redeliveryWorker == nil else { return }
        redeliveryWorker = Task { [weak self] in await self?.runRedelivery() }
    }

    /// Retries kept deliveries every 30 s, and early whenever the queue changes.
    private func runRedelivery() async {
        while !undelivered.isEmpty {
            let wait = Task { [sleep] in _ = try? await sleep(Self.redeliveryInterval) }
            redeliveryWait = wait
            await wait.value
            redeliveryWait = nil
            await attemptRedeliveries()
        }
        redeliveryWorker = nil
    }

    private func attemptRedeliveries() async {
        for pending in undelivered {
            let result = await host.deliver(pending.delivery)
            guard result != .bookUnavailable else { continue }
            undelivered.removeAll { $0.token == pending.token }
            publish()
            persist()
        }
    }
}

/// Prices nothing, so every ledger line is the item's estimate. For the Phase 2 initializer.
struct UnpricedCostPricing: CostPricing {
    func actualCost(of usage: TokenUsage, provider: ProviderID, model: String) -> Decimal? { nil }
    var priceListAsOf: String? { nil }
}
