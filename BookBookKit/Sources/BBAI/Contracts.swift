import BBAICore
import BBModel
import Foundation

// Phase 2 contract (main thread). Implementations live in ModelCatalog.swift,
// ContextAssembler.swift and GenerationQueue.swift (AI lane).

/// What `ContextAssembler` reports alongside the request (A §7.3 step 4).
public struct AssemblyReport: Hashable, Sendable {
    /// The exact text that will be sent.
    public var promptText: String
    public var referencesSent: [SentReference]
    public var referencesOmitted: [SentReference]
    public var storyTextIncluded: Bool
    public var styleRevision: Int
    public var estimatedInputBytes: Int

    public init(promptText: String, referencesSent: [SentReference] = [], referencesOmitted: [SentReference] = [],
                storyTextIncluded: Bool, styleRevision: Int, estimatedInputBytes: Int = 0) {
        self.promptText = promptText
        self.referencesSent = referencesSent
        self.referencesOmitted = referencesOmitted
        self.storyTextIncluded = storyTextIncluded
        self.styleRevision = styleRevision
        self.estimatedInputBytes = estimatedInputBytes
    }
}

/// A queued generation (A §7.9, v0). Intent is fixed at enqueue time; context is assembled
/// from `GenerationHost.content(for:)` when the item starts.
public struct QueueItem: Hashable, Sendable, Identifiable {
    public var id: QueueItemID
    public var bookID: BookID
    public var target: GenerationTarget
    /// The session message this item answers (already appended, with `queueItemID` set).
    public var messageID: MessageID
    public var intent: GenerationIntent

    public init(id: QueueItemID = QueueItemID(), bookID: BookID, target: GenerationTarget, messageID: MessageID,
                intent: GenerationIntent) {
        self.id = id
        self.bookID = bookID
        self.target = target
        self.messageID = messageID
        self.intent = intent
    }
}

public enum QueueItemState: Hashable, Sendable {
    case waiting
    case running(startedAt: Date, progress: GenerationProgress?)
    case failed(ProviderError)
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

/// Published on every queue change. Completed items are removed (their result was delivered).
public struct QueueSnapshot: Hashable, Sendable {
    public var entries: [QueueEntry]
    public init(entries: [QueueEntry] = []) { self.entries = entries }

    public func entry(for id: QueueItemID) -> QueueEntry? { entries.first { $0.id == id } }
}

/// A finished generation, handed to the host to write into the book (A §6.4 `BookWriter`).
public struct GenerationDelivery: Sendable {
    public var item: QueueItem
    public var outcome: Outcome

    public enum Outcome: Sendable {
        /// The host stores `result.imageData`, creates a `.generated` Version with
        /// `provenance`, sets the message's `producedVersion`, clears its `queueItemID`, and
        /// places the version if the box is empty.
        case success(result: ImageResult, provenance: Provenance)
        /// The host clears the message's `queueItemID`. The error stays visible in the queue
        /// snapshot as `.failed`.
        case failure(ProviderError)
    }

    public init(item: QueueItem, outcome: Outcome) {
        self.item = item
        self.outcome = outcome
    }
}

/// Implemented by the app layer (BBUI `BookWriter`). Called from the queue actor.
public protocol GenerationHost: Sendable {
    /// A snapshot of the book, or nil if it's gone (the item then fails as `.unknown`).
    func content(for bookID: BookID) async -> BookContent?
    func deliver(_ delivery: GenerationDelivery) async
    /// Phase 8: the bytes of an image in the book's image store (base image, style references,
    /// attached references), or nil if it's missing. Read when the item starts (A §7.9).
    func imageData(for ref: ImageRef, in bookID: BookID) async -> Data?
}

extension GenerationHost {
    /// Default for hosts that never upload images (test fakes).
    public func imageData(for ref: ImageRef, in bookID: BookID) async -> Data? { nil }
}
