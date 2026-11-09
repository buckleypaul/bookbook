import BBAICore
import BBModel
import CryptoKit
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
/// - Phase 12 (A §7.8): when an image item whose `intent.checkConsistency` is true succeeds and
///   its delivery lands (now or on a later redelivery), a consistency-check item for the new
///   version is inserted before every waiting item, so it runs straight after its parent.
///   Checks run like any item (retries, timeout, ledger line with `kind: .consistency`); a check
///   whose version is gone when it starts is dropped quietly.
public actor GenerationQueue {
    private let providers: [ProviderID: any ImageProvider]
    private let visionProviders: [ProviderID: any VisionProvider]
    private var consistencyInstructions: ConsistencyInstructions
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
    /// Paused at launch because waiting items came back from `queue.json`. The banner's count is
    /// the current waiting items; the pause clears itself when none are left.
    private var restoredPause = false
    private var online = true
    private var hasRestored = false
    /// The run task waits here (after a retry backoff) while the queue is paused.
    private var unpauseWaiter: CheckedContinuation<Void, Never>?

    private var undelivered: [PendingDelivery] = []
    private var redeliveryWorker: Task<Void, Never>?
    /// The worker's current 30 s wait; cancelled to wake it early when the queue changes.
    private var redeliveryWait: Task<Void, Never>?

    /// The save loop in flight (nil when idle); `flushPersistence()` awaits it.
    private var saveTask: Task<Void, Never>?
    private var saveDirty = false
    /// Region edits: blends the provider output through the mask, off the actor. Tests replace it.
    private var compositeRegionEdit: @Sendable (_ raw: Data, _ base: Data?, _ storedMask: Data?) async
        -> Result<RegionEditCompositor.Edit, ProviderError> = {
            await RegionEditCompositor.composite(raw: $0, base: $1, storedMask: $2)
        }

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
                requestTimeout: Duration = .seconds(300),
                visionProviders: [ProviderID: any VisionProvider] = [:],
                consistencyInstructions: @escaping ConsistencyInstructions = ConsistencyPrompt.instructions) {
        self.providers = providers
        self.visionProviders = visionProviders
        self.consistencyInstructions = consistencyInstructions
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
    /// cancelled (estimated ledger line) and its message cleared, not re-queued. Undelivered
    /// results (Phase 16b) come back and are redelivered at once, then every 30 s. Runs once.
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
        if restored.contains(where: { $0.state == .waiting }) { restoredPause = true }
        entries.insert(contentsOf: restored, at: 0)
        let knownTokens = Set(undelivered.map(\.token))
        let spooled = saved.undelivered.filter { !knownTokens.contains($0.token) }.compactMap { saved in
            saved.delivery.map { PendingDelivery(token: saved.token, delivery: $0) }
        }
        undelivered.insert(contentsOf: spooled, at: 0)
        changed()
        if !spooled.isEmpty {
            await attemptRedeliveries()
            if !undelivered.isEmpty { startRedeliveryWorker() }
        }
        for item in interrupted {
            await recordCost(for: item, model: item.intent.model, status: .cancelled, basis: .estimate, actual: nil)
            await deliver(GenerationDelivery(item: item, outcome: .failure(.cancelled)))
        }
        startNextIfIdle()
    }

    /// Adds items (in order) at the end, or before every waiting item. Returns their IDs.
    /// Items already queued, and checks of a version already being checked, are skipped.
    @discardableResult
    public func enqueue(_ items: [QueueItem], position: QueuePosition = .end) -> [QueueItemID] {
        let known = Set(entries.map(\.id))
        // A version is checked once at a time: a check of a version that already has a live
        // (not failed) check is skipped. A version's image never changes, so the result would too.
        var checking = Set(entries.compactMap { entry -> VersionID? in
            if case .failed = entry.state { return nil }
            return entry.item.kind.checkedVersion
        })
        let fresh = items.filter { item in
            guard !known.contains(item.id) else { return false }
            guard let version = item.kind.checkedVersion else { return true }
            return checking.insert(version).inserted
        }
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

    /// Puts a failed item back at the end of the queue. A failed consistency check goes before
    /// every waiting item instead (it belongs straight after its parent), and is dropped if its
    /// version already has another live check.
    public func retry(_ id: QueueItemID) {
        guard let index = entries.firstIndex(where: { $0.id == id }),
              case .failed = entries[index].state else { return }
        let item = entries.remove(at: index).item
        // `enqueue` applies the check dedupe, publishes, saves and starts the next item.
        enqueue([item], position: item.kind.checkedVersion == nil ? .end : .front)
    }

    public func pause() {
        guard !userPaused else { return }
        userPaused = true
        changed()
    }

    /// Clears a user pause and the restored-at-launch pause. An offline pause stays until online.
    public func resume() {
        guard userPaused || restoredPause else { return }
        userPaused = false
        restoredPause = false
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

    /// Replaces the consistency prompt builder (tests; the default is `ConsistencyPrompt.instructions`).
    func setConsistencyInstructions(_ instructions: @escaping ConsistencyInstructions) {
        consistencyInstructions = instructions
    }

    /// Replaces the region-edit compositor (tests).
    func setCompositor(_ compositor: @escaping @Sendable (Data, Data?, Data?) async
        -> Result<RegionEditCompositor.Edit, ProviderError>) {
        compositeRegionEdit = compositor
    }

    /// Used for the next ledger line.
    public func setPricing(_ pricing: any CostPricing) { self.pricing = pricing }

    /// Returns once every queue change so far is saved (quit awaits it, #34a).
    public func flushPersistence() async {
        while let task = saveTask { await task.value }
    }

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
        // `changed()` clears `restoredPause` once no waiting item is left, so there's always one here.
        if restoredPause { return .restored(count: entries.count(where: { $0.state == .waiting })) }
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
        // The restored pause ends with its last waiting item (removed, or started by a resume).
        if restoredPause, !entries.contains(where: { $0.state == .waiting }) {
            restoredPause = false
            if pauseReason == nil {
                unpauseWaiter?.resume()
                unpauseWaiter = nil
            }
        }
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
        }, undelivered: undelivered.map { PersistedDelivery(token: $0.token, delivery: $0.delivery) })
    }

    /// Coalesced: at most one save in flight; the last one always writes the latest state.
    private func persist() {
        guard persistence != nil else { return }
        saveDirty = true
        guard saveTask == nil else { return }
        saveTask = Task { await self.drainSaves() }
    }

    private func drainSaves() async {
        if let persistence {
            while saveDirty {
                saveDirty = false
                await persistence.save(persistedQueue())
            }
        }
        saveTask = nil
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
        if case let .consistencyCheck(version) = item.kind { return await runConsistencyCheck(item, version: version) }
        guard let (provider, model, request, report, storedMask) = await prepare(item) else { return }
        let id = item.id
        let onProgress: @Sendable (Int, GenerationProgress) -> Void = { [weak self] attempt, progress in
            Task { await self?.updateProgress(id, attempt: attempt, progress) }
        }
        let result = await perform(item, model: model.id, report: report) { attempt async throws(ProviderError) in
            try await provider.generate(request) { onProgress(attempt, $0) }
        }
        guard let result else { return }
        await finishSuccess(item, model: model, request: request, storedMask: storedMask, result: result, report: report)
    }

    /// Sends the request with automatic retries (`QueueRetryPolicy`), each attempt raced against
    /// the timeout, writing the ledger lines for failed and cancelled attempts. Returns the
    /// result, or nil once the item has been finished as cancelled or failed.
    private func perform<R: Sendable>(
        _ item: QueueItem, model: String, report: AssemblyReport?,
        _ call: @escaping @Sendable (_ attempt: Int) async throws(ProviderError) -> R
    ) async -> R? {
        var attempt = 1
        while true {
            if isCancelled(item.id) {
                await finishCancelled(item)
                return nil
            }
            current?.inFlight = true
            setState(item.id, .running(startedAt: now(), progress: nil, attempt: attempt))
            let thisAttempt = attempt
            let outcome = await Self.race(timeout: requestTimeout) { () async throws(ProviderError) -> R in
                try await call(thisAttempt)
            }
            current?.inFlight = false

            if isCancelled(item.id) {
                await recordCost(for: item, model: model, status: .cancelled, basis: .estimate, actual: nil)
                await finishCancelled(item)
                return nil
            }
            switch outcome {
            case let .success(result):
                return result
            case let .failure(error):
                switch QueueLedgerRule.forFailure(error) {
                case .none: break
                case .free: await recordCost(for: item, model: model, status: .failed, basis: .actual, actual: 0)
                case let .estimate(status): await recordCost(for: item, model: model, status: status, basis: .estimate, actual: nil)
                }
                guard let delay = retryPolicy.delay(after: error, retriesSoFar: attempt - 1, jitter: jitter()) else {
                    await finishFailed(item, error, report: report, attempts: attempt)
                    return nil
                }
                attempt += 1
                setState(item.id, .retrying(attempt: attempt, resumesAt: now().addingTimeInterval(delay.timeInterval),
                                            lastError: error))
                try? await sleep(delay)
                await waitUntilUnpaused(item.id)
            }
        }
    }

    /// Resolves the provider, model and request, plus the stored region-edit mask's bytes (nil when
    /// not a region edit). On failure the item is finished and nil returned.
    private func prepare(_ item: QueueItem) async
        -> (any ImageProvider, CatalogModel, ImageRequest, AssemblyReport, Data?)? {
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
        guard let prepared = ContextAssembler.prepare(intent: item.intent, target: item.target,
                                                      messageID: item.messageID, content: content) else {
            await finishFailed(item, .unknown(nil), report: nil, attempts: 0)
            return nil
        }
        var imageData: [ImageRef: Data] = [:]
        for image in ContextAssembler.plan(prepared) {
            if let data = await host.imageData(for: image.ref, in: item.bookID) { imageData[image.ref] = data }
        }
        // Region edit (A §7.6): the user's mask is read with the other images.
        if let mask = item.intent.regionMask, imageData[mask] == nil,
           let data = await host.imageData(for: mask, in: item.bookID) {
            imageData[mask] = data
        }
        if isCancelled(item.id) {
            await finishCancelled(item)
            return nil
        }
        do throws(AssemblyError) {
            let (request, report) = try ContextAssembler.assemble(
                prepared: prepared, intent: item.intent, content: content, model: model, imageData: imageData)
            return (provider, model, request, report, item.intent.regionMask.flatMap { imageData[$0] })
        } catch {
            await finishFailed(item, error.providerError, report: nil, attempts: 0)
            return nil
        }
    }

    /// Races the provider call against the request timeout; the loser is cancelled.
    private nonisolated static func race<R: Sendable>(
        timeout: Duration, _ call: @escaping @Sendable () async throws(ProviderError) -> R
    ) async -> Result<R, ProviderError> {
        await withTaskGroup(of: Result<R, ProviderError>?.self) { group in
            group.addTask {
                do throws(ProviderError) {
                    return .success(try await call())
                } catch {
                    return .failure(error)
                }
            }
            group.addTask {
                do { try await Task.sleep(for: timeout) } catch { return nil }
                return .failure(.timeout)
            }
            var outcome: Result<R, ProviderError> = .failure(.cancelled)
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

    private func finishSuccess(_ item: QueueItem, model: CatalogModel, request: ImageRequest, storedMask: Data?,
                               result: ImageResult, report: AssemblyReport) async {
        let actual = result.usage.flatMap {
            pricing.actualCost(of: $0, provider: item.intent.provider, model: model.pricingModelID)
        }
        // The call happened, so it's charged even if a region edit's output is then rejected.
        let costID = await recordCost(for: item, model: model.id, status: .completed,
                                      basis: actual == nil ? .estimate : .actual, actual: actual)
        var provenance = Provenance(
            provider: item.intent.provider, model: model.id, quality: item.intent.quality,
            outputSize: result.pixelSize, promptSent: report.promptText,
            referencesSent: report.referencesSent, referencesOmitted: report.referencesOmitted,
            styleRevision: report.styleRevision, assetRevisions: report.assetRevisions,
            storyTextIncluded: report.storyTextIncluded,
            intent: item.intent, cost: costID, usage: result.usage, revisedPrompt: result.revisedPrompt,
            parametersSent: result.parametersSent)
        var delivered = result
        var additionalImages: [ImageRef: Data] = [:]
        if let maskRef = item.intent.regionMask {
            // Region edit (A §7.6): the provider's output is composited locally through the user's
            // mask; the composite becomes the version and the raw output is kept for Version details.
            let composited = await compositeRegionEdit(result.imageData, request.baseImage?.data, storedMask)
            // A cancel during the off-thread composite wins: the call stays charged, nothing lands.
            if isCancelled(item.id) { return await finishCancelled(item) }
            switch composited {
            case let .failure(error):
                return await finishFailed(item, error, report: report, attempts: 1)
            case let .success(edit):
                let rawRef = Self.imageRef(for: result.imageData, contentType: result.contentType)
                additionalImages[rawRef] = result.imageData
                delivered.imageData = edit.png
                delivered.contentType = "public.png"
                delivered.pixelSize = edit.pixelSize
                provenance.maskSent = maskRef
                provenance.rawOutput = rawRef
                provenance.featherPixels = edit.featherPixels
            }
        }
        entries.removeAll { $0.id == item.id }
        changed()
        await deliver(GenerationDelivery(item: item, outcome: .success(result: delivered, provenance: provenance),
                                         costRecordID: costID, additionalImages: additionalImages,
                                         versionID: VersionID()))
    }

    // MARK: - Consistency checks (A §7.8)

    /// After an image delivery lands: queues its consistency follow-up, ahead of every waiting
    /// item, when the intent asked for one (the Settings switch at enqueue time) and the vision
    /// provider is wired.
    private func queueFollowUp(after delivery: GenerationDelivery) {
        let parent = delivery.item
        guard case .success = delivery.outcome, parent.kind == .image, parent.intent.checkConsistency == true else { return }
        let spec = parent.consistencyFollowUp ?? catalog.textModels(kind: .vision).first { $0.status != .retired }.map {
            ConsistencyFollowUp(provider: $0.provider, model: $0.id, estimate: .unknown)
        }
        // No vision provider wired: there's nothing that could run the check.
        guard let spec, visionProviders[spec.provider] != nil else { return }
        let intent = GenerationIntent(messageText: "", refines: delivery.versionID, provider: spec.provider,
                                      model: spec.model, quality: parent.intent.quality,
                                      includeStoryText: parent.intent.includeStoryText)
        var display = parent.display
        display.boxLabel = ConsistencyQueueLabel.label(for: display.boxLabel)
        let item = QueueItem(bookID: parent.bookID, target: parent.target, messageID: parent.messageID, intent: intent,
                             estimate: spec.estimate, display: display, enqueuedAt: now(),
                             kind: .consistencyCheck(delivery.versionID), parent: parent.id)
        enqueue([item], position: .front)
    }

    private func runConsistencyCheck(_ item: QueueItem, version: VersionID) async {
        // A check of a book that's gone is dropped quietly, like a gone version.
        guard let content = await host.content(for: item.bookID) else { return finishDropped(item) }
        guard let plan = ConsistencyAssembler.plan(version: version, content: content, provider: item.intent.provider)
        else { return finishDropped(item) }
        guard let model = catalog.textModel(provider: item.intent.provider, id: item.intent.model),
              model.kind == .vision else {
            return await finishFailed(item, .modelUnavailable(nil), report: nil, attempts: 0)
        }
        guard let provider = visionProviders[item.intent.provider] else {
            return await finishFailed(item, .unknown(nil), report: nil, attempts: 0)
        }
        var imageData: [ImageRef: Data] = [:]
        for image in [plan.checked] + plan.references where imageData[image.ref] == nil {
            if let data = await host.imageData(for: image.ref, in: item.bookID) { imageData[image.ref] = data }
        }
        if isCancelled(item.id) { return await finishCancelled(item) }
        let assembled: AssembledConsistency
        do throws(AssemblyError) {
            assembled = try ConsistencyAssembler.assemble(plan, model: model, imageData: imageData,
                                                          instructions: consistencyInstructions)
        } catch {
            return await finishFailed(item, error.providerError, report: nil, attempts: 0)
        }
        let request = assembled.request
        let result = await perform(item, model: model.id, report: nil) { _ async throws(ProviderError) in
            try await provider.checkConsistency(request)
        }
        guard let result else { return }

        let actual = result.usage.flatMap { pricing.actualCost(of: $0, provider: item.intent.provider, model: model.id) }
        let costID = await recordCost(for: item, model: model.id, status: .completed,
                                      basis: actual == nil ? .estimate : .actual, actual: actual)
        let thresholds = model.consistency ?? .standard
        let report = ConsistencyReport(
            checkedAt: now(), provider: item.intent.provider, model: model.id, consistent: result.consistent,
            differences: result.differences, warns: thresholds.warns(result.differences),
            sent: ConsistencySent(promptSent: assembled.promptText, imagesSent: assembled.imagesSent,
                                  parametersSent: result.parametersSent),
            cost: costID, usage: result.usage)
        entries.removeAll { $0.id == item.id }
        changed()
        await deliver(GenerationDelivery(item: item, outcome: .consistency(report), costRecordID: costID))
    }

    /// A check whose version (or its page, box, slot or sheet item) is gone: removed without a
    /// request, a ledger line or a delivery.
    private func finishDropped(_ item: QueueItem) {
        entries.removeAll { $0.id == item.id }
        changed()
    }

    /// The content-addressed ref `BookStore.storeImage` gives these bytes (SHA-256, lowercase hex).
    nonisolated static func imageRef(for data: Data, contentType: String) -> ImageRef {
        ImageRef(sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), contentType: contentType)
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
        let isImage = item.kind == .image
        let record = CostRecord(
            at: now(), kind: isImage ? .image : .consistency, provider: item.intent.provider, model: model,
            quality: isImage ? item.intent.quality : nil,
            target: item.target, status: status, estimated: item.estimate.amount ?? 0, actual: actual, basis: basis,
            priceListAsOf: basis == .actual ? pricing.priceListAsOf : (item.estimate.priceListAsOf ?? pricing.priceListAsOf),
            queueItemID: item.id)
        await host.recordCost(record, in: item.bookID)
        return record.id
    }

    // MARK: - Delivery

    private func deliver(_ delivery: GenerationDelivery) async {
        switch await host.deliver(delivery) {
        case .delivered:
            queueFollowUp(after: delivery)
        case .bookGone:
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

    private var isRedelivering = false

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
        // One pass at a time: an overlapping pass would deliver the same picture twice.
        guard !isRedelivering else { return }
        isRedelivering = true
        defer { isRedelivering = false }
        for pending in undelivered {
            let result = await host.deliver(pending.delivery)
            guard result != .bookUnavailable else { continue }
            undelivered.removeAll { $0.token == pending.token }
            publish()
            persist()
            if result == .delivered { queueFollowUp(after: pending.delivery) }
        }
    }
}
