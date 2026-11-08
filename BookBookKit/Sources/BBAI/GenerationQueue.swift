import BBAICore
import BBModel
import Foundation

/// App-wide serial queue, v0 (plan P-4, A §7.9): in memory, one item at a time, no retries,
/// no persistence or reordering (Phase 9).
public actor GenerationQueue {
    private let providers: [ProviderID: any ImageProvider]
    private let catalog: ModelCatalog
    private let host: any GenerationHost
    private let now: @Sendable () -> Date

    private var entries: [QueueEntry] = []
    private var runningTask: Task<Void, Never>?
    private var runningID: QueueItemID?
    private var cancelRequested = false
    private var subscribers: [UUID: AsyncStream<QueueSnapshot>.Continuation] = [:]

    public init(providers: [ProviderID: any ImageProvider], catalog: ModelCatalog, host: any GenerationHost,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.providers = providers
        self.catalog = catalog
        self.host = host
        self.now = now
    }

    /// Appends an item; starts it if nothing is running.
    public func enqueue(_ item: QueueItem) {
        entries.append(QueueEntry(item: item, state: .waiting))
        publish()
        startNextIfIdle()
    }

    /// Cancels the running item (its delivery is `.failure(.cancelled)`).
    public func cancelRunning() {
        guard let task = runningTask else { return }
        cancelRequested = true
        task.cancel()
    }

    /// Removes a waiting or failed item. Does nothing for the running item.
    public func remove(_ id: QueueItemID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        if case .running = entries[index].state { return }
        entries.remove(at: index)
        publish()
    }

    public func snapshot() -> QueueSnapshot { QueueSnapshot(entries: entries) }

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

    // MARK: Running

    private func removeSubscriber(_ token: UUID) {
        subscribers[token] = nil
    }

    private func publish() {
        let current = snapshot()
        for continuation in subscribers.values { continuation.yield(current) }
    }

    private func startNextIfIdle() {
        guard runningTask == nil,
              let index = entries.firstIndex(where: { $0.state == .waiting }) else { return }
        let item = entries[index].item
        entries[index].state = .running(startedAt: now(), progress: nil)
        runningID = item.id
        cancelRequested = false
        publish()
        runningTask = Task { [weak self] in
            await self?.run(item)
            await self?.finishRunning()
        }
    }

    private func finishRunning() {
        runningTask = nil
        runningID = nil
        cancelRequested = false
        startNextIfIdle()
    }

    private func updateProgress(_ id: QueueItemID, _ progress: GenerationProgress) {
        guard let index = entries.firstIndex(where: { $0.id == id }),
              case let .running(startedAt, _) = entries[index].state else { return }
        entries[index].state = .running(startedAt: startedAt, progress: progress)
        publish()
    }

    private func run(_ item: QueueItem) async {
        guard let content = await host.content(for: item.bookID) else {
            return await fail(item, .unknown(nil))
        }
        guard let model = catalog.imageModel(provider: item.intent.provider, id: item.intent.model) else {
            return await fail(item, .modelUnavailable(nil))
        }
        guard let provider = providers[item.intent.provider] else {
            return await fail(item, .unknown(nil))
        }
        guard let (request, report) = ContextAssembler.assemble(intent: item.intent, target: item.target,
                                                                content: content, model: model) else {
            return await fail(item, .unknown(nil))
        }
        let id = item.id
        let result: ImageResult
        do throws(ProviderError) {
            result = try await provider.generate(request, progress: { [weak self] progress in
                Task { await self?.updateProgress(id, progress) }
            })
        } catch {
            return await fail(item, Task.isCancelled || cancelRequested ? .cancelled : error)
        }
        if cancelRequested || Task.isCancelled {
            return await fail(item, .cancelled)
        }
        let provenance = Provenance(
            provider: item.intent.provider, model: model.id, quality: item.intent.quality,
            outputSize: result.pixelSize, promptSent: report.promptText,
            referencesSent: report.referencesSent, referencesOmitted: report.referencesOmitted,
            styleRevision: report.styleRevision, storyTextIncluded: report.storyTextIncluded,
            intent: item.intent, usage: result.usage, revisedPrompt: result.revisedPrompt,
            parametersSent: result.parametersSent)
        await host.deliver(GenerationDelivery(item: item, outcome: .success(result: result, provenance: provenance)))
        entries.removeAll { $0.id == item.id }
        publish()
    }

    private func fail(_ item: QueueItem, _ error: ProviderError) async {
        if error == .cancelled {
            // A cancelled item is not kept: the user asked for it to go.
            entries.removeAll { $0.id == item.id }
        } else if let index = entries.firstIndex(where: { $0.id == item.id }) {
            entries[index].state = .failed(error)
        }
        publish()
        await host.deliver(GenerationDelivery(item: item, outcome: .failure(error)))
    }
}
