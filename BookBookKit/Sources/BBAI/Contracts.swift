import BBAICore
import BBModel
import Foundation

// Phase 2 contract (main thread). Implementations live in ModelCatalog.swift,
// ContextAssembler.swift and GenerationQueue.swift (AI lane).

/// What `ContextAssembler` reports alongside the request (A §7.3 step 4).
public struct AssemblyReport: Hashable, Codable, Sendable {
    /// The exact text that will be sent.
    public var promptText: String
    public var referencesSent: [SentReference]
    public var referencesOmitted: [SentReference]
    public var storyTextIncluded: Bool
    public var styleRevision: Int
    public var estimatedInputBytes: Int
    /// Phase 9: the page's story text as included in the prompt (nil when not included), so
    /// `RefusalAdvisor` can tell prompt words from story words.
    public var storyText: String?
    /// Phase 10: the revision of every asset in play (A §7.3 step 1), for
    /// `Provenance.assetRevisions` and the asset-changed flag.
    public var assetRevisions: [AssetID: Int] = [:]

    public init(promptText: String, referencesSent: [SentReference] = [], referencesOmitted: [SentReference] = [],
                storyTextIncluded: Bool, styleRevision: Int, estimatedInputBytes: Int = 0, storyText: String? = nil) {
        self.storyText = storyText
        self.promptText = promptText
        self.referencesSent = referencesSent
        self.referencesOmitted = referencesOmitted
        self.storyTextIncluded = storyTextIncluded
        self.styleRevision = styleRevision
        self.estimatedInputBytes = estimatedInputBytes
    }
}


// MARK: - Queue (Phase 9 contract, A §7.9)

/// What the queue window and sidebar badge show for an item, captured at enqueue time so a
/// closed book's item still has a label.
public struct QueueItemDisplay: Hashable, Codable, Sendable {
    public var bookTitle: String
    /// e.g. "Page 3", "Cover".
    public var pageLabel: String
    /// e.g. "Image 1".
    public var boxLabel: String

    public init(bookTitle: String, pageLabel: String, boxLabel: String) {
        self.bookTitle = bookTitle
        self.pageLabel = pageLabel
        self.boxLabel = boxLabel
    }
}

/// A queued generation. Intent is fixed at enqueue time; context is assembled from
/// `GenerationHost.content(for:)` when the item starts (A §7.9).
public struct QueueItem: Hashable, Codable, Sendable, Identifiable {
    public var id: QueueItemID
    public var bookID: BookID
    public var target: GenerationTarget
    /// The session message this item answers (already appended, with `queueItemID` set).
    public var messageID: MessageID
    public var intent: GenerationIntent
    /// Made by the caller before enqueueing (`CostEstimator`); used for the ledger entry of a
    /// cancelled or transport-failed request.
    public var estimate: CostEstimate
    public var display: QueueItemDisplay
    public var enqueuedAt: Date

    public init(id: QueueItemID = QueueItemID(), bookID: BookID, target: GenerationTarget, messageID: MessageID,
                intent: GenerationIntent, estimate: CostEstimate = .unknown,
                display: QueueItemDisplay = QueueItemDisplay(bookTitle: "", pageLabel: "", boxLabel: ""),
                enqueuedAt: Date = Date()) {
        self.id = id
        self.bookID = bookID
        self.target = target
        self.messageID = messageID
        self.intent = intent
        self.estimate = estimate
        self.display = display
        self.enqueuedAt = enqueuedAt
    }
}

/// Why an item failed, kept with the failed entry (and persisted) for `RefusalAdvisor`.
public struct QueueFailure: Hashable, Codable, Sendable {
    public var error: ProviderError
    /// What was (or would have been) sent; nil if the failure happened before assembly.
    public var report: AssemblyReport?
    /// Requests made, including automatic retries.
    public var attempts: Int
    public var failedAt: Date

    public init(error: ProviderError, report: AssemblyReport?, attempts: Int, failedAt: Date) {
        self.error = error
        self.report = report
        self.attempts = attempts
        self.failedAt = failedAt
    }
}

public enum QueueItemState: Hashable, Sendable {
    case waiting
    /// `attempt` is 1 for the first request, 2+ for automatic retries.
    case running(startedAt: Date, progress: GenerationProgress?, attempt: Int)
    /// Waiting out a backoff (or `Retry-After`) before automatic retry `attempt`.
    case retrying(attempt: Int, resumesAt: Date, lastError: ProviderError)
    case failed(QueueFailure)
}

public struct QueueEntry: Hashable, Sendable, Identifiable {
    public var item: QueueItem
    public var state: QueueItemState
    public var id: QueueItemID { item.id }
    public init(item: QueueItem, state: QueueItemState) {
        self.item = item
        self.state = state
    }
}

public enum QueuePause: Hashable, Sendable {
    /// Restored at launch; the banner offers "Resume N queued requests".
    case restored(count: Int)
    /// `NWPathMonitor` reports no network; clears itself when the network returns.
    case offline
    /// The user paused it in the queue window.
    case user
}

/// Published on every queue change. Completed items are removed (their result was delivered).
public struct QueueSnapshot: Hashable, Sendable {
    public var entries: [QueueEntry]
    /// nil while running normally. Offline wins over the other reasons while offline.
    public var pause: QueuePause?
    /// Finished results whose book was locked by another process; delivery is retried.
    public var undeliveredCount: Int

    public init(entries: [QueueEntry] = [], pause: QueuePause? = nil, undeliveredCount: Int = 0) {
        self.entries = entries
        self.pause = pause
        self.undeliveredCount = undeliveredCount
    }

    public func entry(for id: QueueItemID) -> QueueEntry? { entries.first { $0.id == id } }
    public var isPaused: Bool { pause != nil }
}

public enum QueuePosition: Hashable, Sendable {
    case end
    /// Before every waiting item (the running item keeps running).
    case front
}

/// A finished generation, handed to the host to write into the book (A §6.4 `BookWriter`).
public struct GenerationDelivery: Sendable {
    public var item: QueueItem
    public var outcome: Outcome
    /// The ledger entry already recorded for this request (via `GenerationHost.recordCost`),
    /// stored as `Provenance.cost` on success.
    public var costRecordID: CostRecordID?
    /// Images the host stores (before the session JSON) alongside the version image, keyed by
    /// their content-addressed ref: a region edit's raw provider output (`Provenance.rawOutput`).
    public var additionalImages: [ImageRef: Data]

    public enum Outcome: Sendable {
        /// The host stores `result.imageData`, creates a `.generated` (`.regionEdit` when the
        /// intent has a `regionMask`; then `result` is the local composite) Version with
        /// `provenance`, sets the message's `producedVersion`, clears its `queueItemID`, and
        /// places the version if the box is empty.
        case success(result: ImageResult, provenance: Provenance)
        /// The host clears the message's `queueItemID`. Sent when an item finally fails, and
        /// with `.cancelled` when the user cancels or removes it. A failed item stays visible in
        /// the queue snapshot as `.failed` until removed or retried.
        case failure(ProviderError)
    }

    public init(item: QueueItem, outcome: Outcome, costRecordID: CostRecordID? = nil,
                additionalImages: [ImageRef: Data] = [:]) {
        self.item = item
        self.outcome = outcome
        self.costRecordID = costRecordID
        self.additionalImages = additionalImages
    }
}

public enum DeliveryResult: Hashable, Sendable {
    case delivered
    /// Locked by another process (or read-only here): the queue keeps the delivery in memory
    /// and retries it later (`QueueSnapshot.undeliveredCount`).
    case bookUnavailable
    /// Deleted or in the Trash: dropped (A §6.4).
    case bookGone
}

/// Implemented by the app layer (BBUI `BookWriter`). Called from the queue actor.
public protocol GenerationHost: Sendable {
    /// A snapshot of the book, or nil if it's gone (the item then fails as `.unknown`).
    func content(for bookID: BookID) async -> BookContent?
    func deliver(_ delivery: GenerationDelivery) async -> DeliveryResult
    /// The bytes of an image in the book's image store (base image, style references,
    /// attached references), or nil if it's missing. Read when the item starts (A §7.9).
    func imageData(for ref: ImageRef, in bookID: BookID) async -> Data?
    /// Appends one ledger line to the book's `costs.jsonl`, open or closed (A §7.10). Called
    /// once per provider request, before the matching delivery.
    func recordCost(_ record: CostRecord, in bookID: BookID) async
}

extension GenerationHost {
    /// Default for hosts that never upload images (test fakes).
    public func imageData(for ref: ImageRef, in bookID: BookID) async -> Data? { nil }
    public func recordCost(_ record: CostRecord, in bookID: BookID) async {}
}

/// Where `queue.json` lives (A §5.5). BBUI implements it over the app-support folder.
public protocol QueuePersistence: Sendable {
    func load() async -> PersistedQueue?
    func save(_ queue: PersistedQueue) async
}

/// The `queue.json` format. Rewritten on every queue change.
public struct PersistedQueue: Hashable, Codable, Sendable {
    public static let currentSchemaVersion = 1

    public struct Entry: Hashable, Codable, Sendable {
        public var item: QueueItem
        /// Set for failed items.
        public var failure: QueueFailure?
        /// The item was running when the file was written: at restore it's recorded as
        /// cancelled (estimated ledger entry) and not re-queued (A §7.9).
        public var wasRunning: Bool

        public init(item: QueueItem, failure: QueueFailure? = nil, wasRunning: Bool = false) {
            self.item = item
            self.failure = failure
            self.wasRunning = wasRunning
        }
    }

    public var schemaVersion: Int
    public var entries: [Entry]

    public init(schemaVersion: Int = PersistedQueue.currentSchemaVersion, entries: [Entry]) {
        self.schemaVersion = schemaVersion
        self.entries = entries
    }
}
