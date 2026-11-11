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

    /// At least one image sent was imported as a photo of a real person (A §11, §7.11 rule 1).
    public var sentRealPersonPhoto: Bool { referencesSent.contains { $0.depictsRealPerson } }
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

/// What a queue item does (A §7.9 `target`). Phase 12.
public enum QueueJobKind: Hashable, Codable, Sendable {
    /// An image generation (the only kind before Phase 12).
    case image
    /// A consistency check of one version (A §7.8): compares it with the references of the
    /// assets in play and writes a `ConsistencyReport` onto it. Never a new version, not undoable.
    case consistencyCheck(VersionID)

    /// The version a consistency check looks at; nil for image items.
    public var checkedVersion: VersionID? {
        if case let .consistencyCheck(id) = self { return id }
        return nil
    }
}

/// The consistency follow-up an image item queues when it succeeds (A §7.8), decided at enqueue
/// time: the Settings default vision model and the follow-up's own estimate.
public struct ConsistencyFollowUp: Hashable, Codable, Sendable {
    public var provider: ProviderID
    /// A catalog `kind: vision` model ID.
    public var model: String
    /// The check's estimate. Shown as part of the parent's estimate; the parent's ledger line
    /// still prices only its own request.
    public var estimate: CostEstimate

    public init(provider: ProviderID, model: String, estimate: CostEstimate) {
        self.provider = provider
        self.model = model
        self.estimate = estimate
    }
}

/// A queued generation. Intent is fixed at enqueue time; context is assembled from
/// `GenerationHost.content(for:)` when the item starts (A §7.9).
///
/// Phase 12: consistency checks are queue items too (`kind`). Their `intent` carries the vision
/// provider and model (`provider`, `model`) and `refines` = the checked version; `target` and
/// `messageID` are the checked version's session owner and producing message (a fresh ID when
/// there is none) and are used only for labels. A follow-up's `parent` is the image item whose
/// version it checks.
public struct QueueItem: Hashable, Codable, Sendable, Identifiable {
    public var id: QueueItemID
    public var bookID: BookID
    public var target: GenerationTarget
    /// The session message this item answers (already appended, with `queueItemID` set).
    public var messageID: MessageID
    public var intent: GenerationIntent
    /// Made by the caller before enqueueing (`CostEstimator`); used for the ledger entry of a
    /// cancelled or transport-failed request. This request only, never its follow-up.
    public var estimate: CostEstimate
    public var display: QueueItemDisplay
    public var enqueuedAt: Date
    /// Phase 12. Items in older `queue.json` files are `.image`.
    public var kind: QueueJobKind
    /// Phase 12: the image item a consistency follow-up belongs to.
    public var parent: QueueItemID?
    /// Phase 12: on image items whose `intent.checkConsistency` is true, the follow-up to queue
    /// when the result lands. nil = the queue falls back to the catalog's first vision model.
    public var consistencyFollowUp: ConsistencyFollowUp?

    public init(id: QueueItemID = QueueItemID(), bookID: BookID, target: GenerationTarget, messageID: MessageID,
                intent: GenerationIntent, estimate: CostEstimate = .unknown,
                display: QueueItemDisplay = QueueItemDisplay(bookTitle: "", pageLabel: "", boxLabel: ""),
                enqueuedAt: Date = Date(), kind: QueueJobKind = .image, parent: QueueItemID? = nil,
                consistencyFollowUp: ConsistencyFollowUp? = nil) {
        self.id = id
        self.bookID = bookID
        self.target = target
        self.messageID = messageID
        self.intent = intent
        self.estimate = estimate
        self.display = display
        self.enqueuedAt = enqueuedAt
        self.kind = kind
        self.parent = parent
        self.consistencyFollowUp = consistencyFollowUp
    }

    /// What the user is shown before enqueueing: this request plus its consistency follow-up.
    public var estimateIncludingFollowUp: CostEstimate {
        guard let followUp = consistencyFollowUp, intent.checkConsistency == true else { return estimate }
        return CostEstimate.total([estimate, followUp.estimate])
    }

    private enum CodingKeys: String, CodingKey {
        case id, bookID, target, messageID, intent, estimate, display, enqueuedAt, kind, parent, consistencyFollowUp
    }

    /// Phase 9 files have no `kind`, `parent` or `consistencyFollowUp`.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(QueueItemID.self, forKey: .id)
        bookID = try c.decode(BookID.self, forKey: .bookID)
        target = try c.decode(GenerationTarget.self, forKey: .target)
        messageID = try c.decode(MessageID.self, forKey: .messageID)
        intent = try c.decode(GenerationIntent.self, forKey: .intent)
        estimate = try c.decode(CostEstimate.self, forKey: .estimate)
        display = try c.decode(QueueItemDisplay.self, forKey: .display)
        enqueuedAt = try c.decode(Date.self, forKey: .enqueuedAt)
        kind = try c.decodeIfPresent(QueueJobKind.self, forKey: .kind) ?? .image
        parent = try c.decodeIfPresent(QueueItemID.self, forKey: .parent)
        consistencyFollowUp = try c.decodeIfPresent(ConsistencyFollowUp.self, forKey: .consistencyFollowUp)
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
    /// Phase 12: the ID the new version gets on success. Assigned by the queue, so a consistency
    /// follow-up can name the version, and a redelivery writes the same ID.
    public var versionID: VersionID

    public enum Outcome: Sendable {
        /// The host stores `result.imageData`, creates a Version with ID `versionID`, source
        /// `intent.versionSource`, else `.generated` (`.regionEdit` when the intent has a
        /// `regionMask`; then `result` is the local composite), and `provenance`; sets the
        /// message's `producedVersion`, clears its `queueItemID`, and places the version if the
        /// box is empty.
        case success(result: ImageResult, provenance: Provenance)
        /// The host clears the message's `queueItemID`. Sent when an item finally fails, and
        /// with `.cancelled` when the user cancels or removes it. A failed item stays visible in
        /// the queue snapshot as `.failed` until removed or retried. For a consistency check
        /// (`item.kind`) the host changes nothing: the checked version is left as it was.
        case failure(ProviderError)
        /// Phase 12: a finished consistency check. The host sets the checked version's
        /// `consistency` (`item.kind.checkedVersion`), replacing an earlier report, and changes
        /// nothing else (not a version, not undoable). Dropped quietly if the version is gone.
        case consistency(ConsistencyReport)
    }

    public init(item: QueueItem, outcome: Outcome, costRecordID: CostRecordID? = nil,
                additionalImages: [ImageRef: Data] = [:], versionID: VersionID = VersionID()) {
        self.item = item
        self.outcome = outcome
        self.costRecordID = costRecordID
        self.additionalImages = additionalImages
        self.versionID = versionID
    }
}

public enum DeliveryResult: Hashable, Sendable {
    case delivered
    /// Locked by another process (or read-only here): the queue keeps the delivery (saved in
    /// `queue.json`, Phase 16b) and retries it later, and at the next launch (`QueueSnapshot.undeliveredCount`).
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
    /// 2 (Phase 12): items may be consistency checks (`QueueItem.kind`). Version 1 files still
    /// decode (every item is an image item); builds before Phase 12 ignore a version 2 file
    /// rather than run a check as an image request.
    /// 3 (Phase 16b): `undelivered` lists finished results whose book was locked; their image
    /// bytes live in spool files next to `queue.json`. Version 1 and 2 files decode with none.
    public static let currentSchemaVersion = 3

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
    /// Phase 16b: deliveries waiting for their book (`DeliveryResult.bookUnavailable`), oldest
    /// first. Redelivered after `restore()`.
    public var undelivered: [PersistedDelivery]

    public init(schemaVersion: Int = PersistedQueue.currentSchemaVersion, entries: [Entry],
                undelivered: [PersistedDelivery] = []) {
        self.schemaVersion = schemaVersion
        self.entries = entries
        self.undelivered = undelivered
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, entries, undelivered }

    /// Files before schema 3 have no `undelivered`. Entries and deliveries for a legacy
    /// character-sheet item (removed 2026-11-11; their target throws `LegacySheetItemError`) are
    /// dropped; any other undecodable entry still fails the whole file.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        entries = try Self.decodeDroppingLegacySheetItems(Entry.self, c.nestedUnkeyedContainer(forKey: .entries))
        if c.contains(.undelivered), try !c.decodeNil(forKey: .undelivered) {
            undelivered = try Self.decodeDroppingLegacySheetItems(PersistedDelivery.self,
                                                                  c.nestedUnkeyedContainer(forKey: .undelivered))
        } else {
            undelivered = []
        }
    }

    /// Decodes nothing; used to step past an element that failed to decode.
    private struct Skipped: Decodable {
        init(from decoder: any Decoder) throws {}
    }

    private static func decodeDroppingLegacySheetItems<T: Decodable>(
        _ type: T.Type, _ container: any UnkeyedDecodingContainer) throws -> [T] {
        var container = container
        var out: [T] = []
        while !container.isAtEnd {
            do {
                out.append(try container.decode(T.self))
            } catch is LegacySheetItemError {
                _ = try container.decode(Skipped.self)
            }
        }
        return out
    }

    /// Per book, the image file names in its `images/` that queued work still needs and the
    /// open-time sweep must keep (#29a).
    public var protectedImageFileNames: [BookID: Set<String>] {
        var names: [BookID: Set<String>] = [:]
        for entry in entries { names[entry.item.bookID, default: []].formUnion(entry.bookImageFileNames) }
        for delivery in undelivered { names[delivery.item.bookID, default: []].formUnion(delivery.bookImageFileNames) }
        return names
    }
}

/// An image a persisted delivery needs, kept as a spool file (`QueuePersistence` writes and
/// reads the bytes; only `fileName` and `ref` are encoded).
public struct SpooledImage: Hashable, Codable, Sendable {
    /// The file name in the persistence's spool folder (`<token>.<ext>`, or
    /// `<token>-<sha256>.<ext>` for an additional image).
    public var fileName: String
    /// nil = the result image; otherwise the additional image's ref (`GenerationDelivery.additionalImages`).
    public var ref: ImageRef?
    /// Not encoded. Empty after decoding until the persistence reads the spool file.
    public var data: Data

    public init(fileName: String, ref: ImageRef?, data: Data) {
        self.fileName = fileName
        self.ref = ref
        self.data = data
    }

    private enum CodingKeys: String, CodingKey { case fileName, ref }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fileName = try c.decode(String.self, forKey: .fileName)
        ref = try c.decodeIfPresent(ImageRef.self, forKey: .ref)
        data = Data()
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(fileName, forKey: .fileName)
        try c.encodeIfPresent(ref, forKey: .ref)
    }
}

/// Phase 16b (#42a): a `GenerationDelivery` the host couldn't write yet, as saved in
/// `queue.json`. Image bytes are in `images` (spool files), never in the JSON.
public struct PersistedDelivery: Hashable, Codable, Sendable {
    public enum Outcome: Hashable, Codable, Sendable {
        /// `GenerationDelivery.Outcome.success` without the image bytes (`images` holds them).
        case success(contentType: String, pixelSize: PixelSize, usage: TokenUsage?, revisedPrompt: String?,
                     parametersSent: [String: String], provenance: Provenance)
        case failure(ProviderError)
        case consistency(ConsistencyReport)
    }

    /// Identifies the delivery across launches; names its spool files.
    public var token: UUID
    public var item: QueueItem
    public var outcome: Outcome
    public var costRecordID: CostRecordID?
    public var versionID: VersionID
    public var images: [SpooledImage]

    public init(token: UUID, item: QueueItem, outcome: Outcome, costRecordID: CostRecordID?, versionID: VersionID,
                images: [SpooledImage]) {
        self.token = token
        self.item = item
        self.outcome = outcome
        self.costRecordID = costRecordID
        self.versionID = versionID
        self.images = images
    }

    public init(token: UUID, delivery: GenerationDelivery) {
        var images: [SpooledImage] = []
        let outcome: Outcome
        switch delivery.outcome {
        case let .success(result, provenance):
            let ext = ImageRef(sha256: "", contentType: result.contentType).fileExtension
            images.append(SpooledImage(fileName: "\(token.uuidString).\(ext)", ref: nil, data: result.imageData))
            outcome = .success(contentType: result.contentType, pixelSize: result.pixelSize, usage: result.usage,
                               revisedPrompt: result.revisedPrompt, parametersSent: result.parametersSent,
                               provenance: provenance)
        case let .failure(error):
            outcome = .failure(error)
        case let .consistency(report):
            outcome = .consistency(report)
        }
        for (ref, data) in delivery.additionalImages.sorted(by: { $0.key.sha256 < $1.key.sha256 }) {
            images.append(SpooledImage(fileName: "\(token.uuidString)-\(ref.fileName)", ref: ref, data: data))
        }
        self.init(token: token, item: delivery.item, outcome: outcome, costRecordID: delivery.costRecordID,
                  versionID: delivery.versionID, images: images)
    }

    /// The delivery again; nil when an image's bytes are missing.
    public var delivery: GenerationDelivery? {
        let deliveryOutcome: GenerationDelivery.Outcome
        switch outcome {
        case let .success(contentType, pixelSize, usage, revisedPrompt, parametersSent, provenance):
            guard let data = images.first(where: { $0.ref == nil })?.data, !data.isEmpty else { return nil }
            let result = ImageResult(imageData: data, contentType: contentType, pixelSize: pixelSize, usage: usage,
                                     revisedPrompt: revisedPrompt, parametersSent: parametersSent)
            deliveryOutcome = .success(result: result, provenance: provenance)
        case let .failure(error):
            deliveryOutcome = .failure(error)
        case let .consistency(report):
            deliveryOutcome = .consistency(report)
        }
        var additional: [ImageRef: Data] = [:]
        for image in images {
            guard let ref = image.ref else { continue }
            guard !image.data.isEmpty else { return nil }
            additional[ref] = image.data
        }
        return GenerationDelivery(item: item, outcome: deliveryOutcome, costRecordID: costRecordID,
                                  additionalImages: additional, versionID: versionID)
    }

    /// Image file names in the book's `images/` this delivery will reference once written
    /// (the region mask and sent references), which the open-time sweep must keep (#29a).
    public var bookImageFileNames: Set<String> {
        var refs: [ImageRef] = item.intent.regionMask.map { [$0] } ?? []
        if case let .success(_, _, _, _, _, provenance) = outcome {
            refs += provenance.referencesSent.map(\.image) + provenance.referencesOmitted.map(\.image)
            refs += [provenance.maskSent, provenance.intent.regionMask].compactMap { $0 }
        }
        return Set(refs.map(\.fileName))
    }
}

extension PersistedQueue.Entry {
    /// Image file names in the book's `images/` this entry needs while it's queued: the region
    /// mask (not in the book's JSON until the edit lands) and, for a failed item, the images its
    /// report names. Refine bases and attached references are versions the book's JSON still
    /// holds, so the sweep keeps their images already.
    public var bookImageFileNames: Set<String> {
        var refs: [ImageRef] = item.intent.regionMask.map { [$0] } ?? []
        if let report = failure?.report {
            refs += report.referencesSent.map(\.image) + report.referencesOmitted.map(\.image)
        }
        return Set(refs.map(\.fileName))
    }
}
