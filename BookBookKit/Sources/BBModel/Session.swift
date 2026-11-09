import Foundation

// Sessions and versions (architecture.md §4.3). Phase 2 uses page-box sessions only.

/// `sessions/<id>.json`.
public struct Session: Hashable, Codable, Sendable, Identifiable {
    public var id: SessionID
    public var owner: SessionOwner
    /// A single linear thread.
    public var messages: [Message]
    /// Version strip order.
    public var versions: [Version]
    /// Bumped on reset; messages from earlier epochs are hidden.
    public var resetEpoch: Int

    public init(id: SessionID = SessionID(), owner: SessionOwner, messages: [Message] = [],
                versions: [Version] = [], resetEpoch: Int = 0) {
        self.id = id
        self.owner = owner
        self.messages = messages
        self.versions = versions
        self.resetEpoch = resetEpoch
    }

    public func version(_ id: VersionID) -> Version? { versions.first { $0.id == id } }
}

public enum SessionOwner: Hashable, Codable, Sendable {
    case pageBox(PageID, BoxID)
    /// Phase 10: an asset's reference slot (`ReferenceSlot.id`).
    case assetReference(AssetID, UUID)
    /// Phase 10: a character-sheet item (`SheetItem.id`).
    case sheetItem(AssetID, UUID)

    /// The asset that owns this session, if any.
    public var assetID: AssetID? {
        switch self {
        case .pageBox: nil
        case let .assetReference(asset, _), let .sheetItem(asset, _): asset
        }
    }
}

public enum MessageRole: String, Codable, Sendable {
    case user, assistant, system
}

public struct VersionRef: Hashable, Codable, Sendable {
    public var sessionID: SessionID
    public var versionID: VersionID
    public init(sessionID: SessionID, versionID: VersionID) {
        self.sessionID = sessionID
        self.versionID = versionID
    }
}

public struct Message: Hashable, Codable, Sendable, Identifiable {
    public var id: MessageID
    public var epoch: Int
    public var role: MessageRole
    /// Mentions encoded as tokens: ⟦asset:<uuid>⟧ (Phase 10).
    public var text: String
    /// The version that was selected when this was sent.
    public var refines: VersionID?
    public var attachedReferences: [VersionRef]
    public var producedVersion: VersionID?
    /// Set while the request is queued or running; the session shows it as pending.
    public var queueItemID: QueueItemID?
    public var createdAt: Date

    public init(id: MessageID = MessageID(), epoch: Int = 0, role: MessageRole, text: String,
                refines: VersionID? = nil, attachedReferences: [VersionRef] = [],
                producedVersion: VersionID? = nil, queueItemID: QueueItemID? = nil, createdAt: Date) {
        self.id = id
        self.epoch = epoch
        self.role = role
        self.text = text
        self.refines = refines
        self.attachedReferences = attachedReferences
        self.producedVersion = producedVersion
        self.queueItemID = queueItemID
        self.createdAt = createdAt
    }
}

public enum VersionSource: String, Codable, Sendable {
    case generated, imported, regionEdit, consistencyFix
}

public struct Version: Hashable, Codable, Sendable, Identifiable {
    public var id: VersionID
    public var image: ImageRef
    public var pixelSize: PixelSize
    public var source: VersionSource
    /// The version that was refined, if any.
    public var parent: VersionID?
    public var createdAt: Date
    public var starred: Bool
    /// nil for imported versions.
    public var provenance: Provenance?
    /// Phase 10 (A §11): the import question "Is this a photo of a real person?". nil = not
    /// asked (generated versions, page-box imports, older files) = treated as false.
    public var depictsRealPerson: Bool?
    /// Phase 12 (A §7.8): the latest consistency check, automatic or on demand. nil = never checked.
    public var consistency: ConsistencyReport?

    public init(id: VersionID = VersionID(), image: ImageRef, pixelSize: PixelSize, source: VersionSource,
                parent: VersionID? = nil, createdAt: Date, starred: Bool = false, provenance: Provenance? = nil,
                depictsRealPerson: Bool? = nil, consistency: ConsistencyReport? = nil) {
        self.depictsRealPerson = depictsRealPerson
        self.consistency = consistency
        self.id = id
        self.image = image
        self.pixelSize = pixelSize
        self.source = source
        self.parent = parent
        self.createdAt = createdAt
        self.starred = starred
        self.provenance = provenance
    }
}

/// An image that was (or wasn't) sent with a request.
public struct SentReference: Hashable, Codable, Sendable {
    public var image: ImageRef
    /// e.g. `base`, `style`, `asset`.
    public var role: String
    public var label: String

    public init(image: ImageRef, role: String, label: String) {
        self.image = image
        self.role = role
        self.label = label
    }
}

/// The replayable user intent ("Regenerate with same settings"), fixed at enqueue time.
public struct GenerationIntent: Hashable, Codable, Sendable {
    public var messageText: String
    public var refines: VersionID?
    public var attachedReferences: [VersionRef]
    public var provider: ProviderID
    public var model: String
    public var quality: QualityLevel
    public var includeStoryText: Bool
    /// Region edit (Phase 11): the user's 8-bit mask, stored in the book's `images/` at the base
    /// version's pixel size (white = edit area, black = keep). Requires `refines`. nil otherwise.
    public var regionMask: ImageRef?
    /// Phase 12 (A §7.8): queue a consistency follow-up after this generation succeeds. Captured
    /// from the Settings switch at enqueue time. nil (older files) = false.
    public var checkConsistency: Bool?
    /// Phase 12: the source recorded on the resulting version when it isn't derived (e.g.
    /// `.consistencyFix` for a one-click fix). nil = `.generated`, or `.regionEdit` with a mask.
    public var versionSource: VersionSource?

    public init(messageText: String, refines: VersionID? = nil, attachedReferences: [VersionRef] = [],
                provider: ProviderID, model: String, quality: QualityLevel, includeStoryText: Bool = true,
                regionMask: ImageRef? = nil, checkConsistency: Bool? = nil, versionSource: VersionSource? = nil) {
        self.checkConsistency = checkConsistency
        self.versionSource = versionSource
        self.messageText = messageText
        self.refines = refines
        self.attachedReferences = attachedReferences
        self.provider = provider
        self.model = model
        self.quality = quality
        self.includeStoryText = includeStoryText
        self.regionMask = regionMask
    }
}

/// Everything needed to audit and replay a generation (shown in Version details, A §11).
public struct Provenance: Hashable, Codable, Sendable {
    public var provider: ProviderID
    public var model: String
    public var quality: QualityLevel
    public var outputSize: PixelSize
    /// The exact composed text sent.
    public var promptSent: String
    /// In the order sent.
    public var referencesSent: [SentReference]
    public var referencesOmitted: [SentReference]
    public var styleRevision: Int
    public var assetRevisions: [AssetID: Int]
    public var storyTextIncluded: Bool
    public var intent: GenerationIntent
    /// The ledger entry (Phase 9). nil until the ledger exists.
    public var cost: CostRecordID?
    /// Usage when the provider reported it.
    public var usage: TokenUsage?
    /// The provider's revised prompt, if it returned one.
    public var revisedPrompt: String?
    /// Every wire parameter sent besides the prompt and images (e.g. `size`, `quality`,
    /// `output_format`, `moderation`, `n`), so Version details shows everything sent.
    public var parametersSent: [String: String]
    /// Region edit (Phase 11): the mask sent with the request (the user's 8-bit mask image).
    public var maskSent: ImageRef?
    /// Region edit (Phase 11): the provider's raw output before the local composite. The version's
    /// own image is the composite; Version details shows both.
    public var rawOutput: ImageRef?
    /// Region edit (Phase 11): the feather width of the local composite, in pixels.
    public var featherPixels: Double?

    public init(provider: ProviderID, model: String, quality: QualityLevel, outputSize: PixelSize, promptSent: String,
                referencesSent: [SentReference] = [], referencesOmitted: [SentReference] = [], styleRevision: Int,
                assetRevisions: [AssetID: Int] = [:], storyTextIncluded: Bool, intent: GenerationIntent,
                cost: CostRecordID? = nil, usage: TokenUsage? = nil, revisedPrompt: String? = nil,
                parametersSent: [String: String] = [:], maskSent: ImageRef? = nil, rawOutput: ImageRef? = nil,
                featherPixels: Double? = nil) {
        self.maskSent = maskSent
        self.rawOutput = rawOutput
        self.featherPixels = featherPixels
        self.provider = provider
        self.model = model
        self.quality = quality
        self.outputSize = outputSize
        self.promptSent = promptSent
        self.referencesSent = referencesSent
        self.referencesOmitted = referencesOmitted
        self.styleRevision = styleRevision
        self.assetRevisions = assetRevisions
        self.storyTextIncluded = storyTextIncluded
        self.intent = intent
        self.cost = cost
        self.usage = usage
        self.revisedPrompt = revisedPrompt
        self.parametersSent = parametersSent
    }
}

/// What a queued generation writes into (A §7.9). Phase 2: page boxes only.
public enum GenerationTarget: Hashable, Codable, Sendable {
    case pageBox(PageID, BoxID)
    /// Phase 10: an asset reference slot / a character-sheet item.
    case assetReference(AssetID, UUID)
    case sheetItem(AssetID, UUID)

    public var owner: SessionOwner {
        switch self {
        case let .pageBox(p, b): .pageBox(p, b)
        case let .assetReference(a, s): .assetReference(a, s)
        case let .sheetItem(a, i): .sheetItem(a, i)
        }
    }
}
