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

public enum SessionOwner: Hashable, Sendable {
    case pageBox(PageID, BoxID)
    /// The asset's one image session (`Asset.sessionID`).
    case asset(AssetID)
    /// A page text box's AI styling session (`Page.textStyles`, A §7.13).
    case textBox(PageID, BoxID)

    /// The asset that owns this session, if any.
    public var assetID: AssetID? {
        switch self {
        case .pageBox, .textBox: nil
        case let .asset(asset): asset
        }
    }
}

/// Coding keys shared by `SessionOwner` and `GenerationTarget`, matching the synthesized enum
/// format (`{"pageBox":{"_0":…,"_1":…}}`). `assetReference` and `sheetItem` are legacy cases
/// (before 2026-11-11) that are only decoded.
private enum OwnerCaseKey: String, CodingKey { case pageBox, asset, textBox, assetReference, sheetItem }
private enum OwnerValueKey: String, CodingKey { case _0, _1 }

/// Thrown when decoding a legacy character-sheet owner or target: the sheet no longer exists,
/// so loaders drop the session or queue entry.
public struct LegacySheetItemError: Error, Hashable, Sendable {
    public let asset: AssetID
}

private enum OwnerCoding {
    static func decode(_ decoder: any Decoder) throws -> SessionOwner {
        let c = try decoder.container(keyedBy: OwnerCaseKey.self)
        guard let key = c.allKeys.first, c.allKeys.count == 1 else {
            throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath, debugDescription: "Expected one owner case"))
        }
        let v = try c.nestedContainer(keyedBy: OwnerValueKey.self, forKey: key)
        switch key {
        case .pageBox: return .pageBox(try v.decode(PageID.self, forKey: ._0), try v.decode(BoxID.self, forKey: ._1))
        case .textBox: return .textBox(try v.decode(PageID.self, forKey: ._0), try v.decode(BoxID.self, forKey: ._1))
        case .asset, .assetReference: return .asset(try v.decode(AssetID.self, forKey: ._0))
        case .sheetItem: throw LegacySheetItemError(asset: try v.decode(AssetID.self, forKey: ._0))
        }
    }

    static func encode(_ owner: SessionOwner, _ encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: OwnerCaseKey.self)
        switch owner {
        case let .pageBox(p, b):
            var v = c.nestedContainer(keyedBy: OwnerValueKey.self, forKey: .pageBox)
            try v.encode(p, forKey: ._0)
            try v.encode(b, forKey: ._1)
        case let .asset(a):
            var v = c.nestedContainer(keyedBy: OwnerValueKey.self, forKey: .asset)
            try v.encode(a, forKey: ._0)
        case let .textBox(p, b):
            var v = c.nestedContainer(keyedBy: OwnerValueKey.self, forKey: .textBox)
            try v.encode(p, forKey: ._0)
            try v.encode(b, forKey: ._1)
        }
    }
}

extension SessionOwner: Codable {
    /// Legacy `assetReference(asset, slot)` decodes as `.asset(asset)` (a non-primary slot's
    /// session then doesn't match `Asset.sessionID`, and the loader drops it); legacy
    /// `sheetItem` throws `LegacySheetItemError`.
    public init(from decoder: any Decoder) throws { self = try OwnerCoding.decode(decoder) }
    public func encode(to encoder: any Encoder) throws { try OwnerCoding.encode(self, encoder) }
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
    /// The image was imported as a photo of a real person (A §11), so refusal advice can say so
    /// (A §7.11 rule 1). Additive: absent in older books and queue files (= false), and only
    /// written when true, so existing files and snapshots are unchanged.
    public var depictsRealPerson: Bool

    public init(image: ImageRef, role: String, label: String, depictsRealPerson: Bool = false) {
        self.image = image
        self.role = role
        self.label = label
        self.depictsRealPerson = depictsRealPerson
    }

    private enum CodingKeys: String, CodingKey {
        case image, role, label, depictsRealPerson
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        image = try c.decode(ImageRef.self, forKey: .image)
        role = try c.decode(String.self, forKey: .role)
        label = try c.decode(String.self, forKey: .label)
        depictsRealPerson = try c.decodeIfPresent(Bool.self, forKey: .depictsRealPerson) ?? false
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(image, forKey: .image)
        try c.encode(role, forKey: .role)
        try c.encode(label, forKey: .label)
        if depictsRealPerson { try c.encode(true, forKey: .depictsRealPerson) }
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
    /// AI text styling (A §7.13): the text model's answer, fixed when the decoration is queued.
    /// nil for picture generations (and older files).
    public var textStyle: TextStyleIntent?

    public init(messageText: String, refines: VersionID? = nil, attachedReferences: [VersionRef] = [],
                provider: ProviderID, model: String, quality: QualityLevel, includeStoryText: Bool = true,
                regionMask: ImageRef? = nil, checkConsistency: Bool? = nil, versionSource: VersionSource? = nil,
                textStyle: TextStyleIntent? = nil) {
        self.textStyle = textStyle
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

/// What a queued generation writes into (A §7.9).
public enum GenerationTarget: Hashable, Sendable {
    case pageBox(PageID, BoxID)
    /// The asset's one image session.
    case asset(AssetID)
    /// A page text box's styling decoration (A §7.13).
    case textBox(PageID, BoxID)

    public var owner: SessionOwner {
        switch self {
        case let .pageBox(p, b): .pageBox(p, b)
        case let .asset(a): .asset(a)
        case let .textBox(p, b): .textBox(p, b)
        }
    }

    public init(owner: SessionOwner) {
        switch owner {
        case let .pageBox(p, b): self = .pageBox(p, b)
        case let .asset(a): self = .asset(a)
        case let .textBox(p, b): self = .textBox(p, b)
        }
    }
}

extension GenerationTarget: Codable {
    /// Same format and legacy handling as `SessionOwner` (a legacy sheet-item target throws
    /// `LegacySheetItemError`, so the queue loader drops that entry).
    public init(from decoder: any Decoder) throws { self.init(owner: try OwnerCoding.decode(decoder)) }
    public func encode(to encoder: any Encoder) throws { try OwnerCoding.encode(owner, encoder) }
}
