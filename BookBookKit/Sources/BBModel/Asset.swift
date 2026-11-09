import Foundation

// Phase 10 contract (main thread). A §4.2 `Asset`/`ReferenceSlot`/`CharacterSheet`, A §4.3
// mention tokens, A §4.4 asset changed and where-used. Implementations marked
// "Lane: model" are filled in by the model lane; signatures are frozen.

public enum AssetType: String, Codable, Sendable, CaseIterable {
    case character, place, object
}

public enum SheetView: String, Codable, Sendable, CaseIterable {
    case front, threeQuarter, side, back
}

/// A character-sheet item: a turnaround view or an expression (built-in or custom; the name
/// is what `ReferenceSelector` matches, lower-cased).
public enum SheetItemKind: Hashable, Codable, Sendable {
    case view(SheetView)
    case expression(String)
}

public struct ReferenceSlot: Hashable, Codable, Sendable, Identifiable {
    public var id: UUID
    public var label: String
    public var isPrimary: Bool
    public var sessionID: SessionID
    /// The version of `sessionID` used as this reference; nil = nothing chosen yet (not sent).
    public var chosen: VersionID?

    public init(id: UUID = UUID(), label: String, isPrimary: Bool, sessionID: SessionID = SessionID(),
                chosen: VersionID? = nil) {
        self.id = id
        self.label = label
        self.isPrimary = isPrimary
        self.sessionID = sessionID
        self.chosen = chosen
    }
}

public struct SheetItem: Hashable, Codable, Sendable, Identifiable {
    public var id: UUID
    public var kind: SheetItemKind
    public var sessionID: SessionID
    public var chosen: VersionID?
    /// Locked items are skipped by Generate whole sheet. (`ReferenceSelector` skips unchosen
    /// items; A §7.4 also says locked, but the plan reads "lock" as "keep this one", so a
    /// locked, chosen item is still sent — main-thread decision, logged in Phase 10.)
    public var locked: Bool

    public init(id: UUID = UUID(), kind: SheetItemKind, sessionID: SessionID = SessionID(),
                chosen: VersionID? = nil, locked: Bool = false) {
        self.id = id
        self.kind = kind
        self.sessionID = sessionID
        self.chosen = chosen
        self.locked = locked
    }
}

public struct CharacterSheet: Hashable, Codable, Sendable {
    public var items: [SheetItem]
    public init(items: [SheetItem] = []) { self.items = items }

    /// The default sheet for a new character (Phase 10 decision, 2026-11-08): the primary
    /// reference is the front view, so three views plus five expressions = 8 items.
    public static func makeDefault() -> CharacterSheet {
        CharacterSheet(items: [SheetView.threeQuarter, .side, .back].map { SheetItem(kind: .view($0)) }
            + defaultExpressions.map { SheetItem(kind: .expression($0)) })
    }

    public static let defaultExpressions = ["happy", "sad", "surprised", "angry", "sleepy"]
}

public struct Asset: Hashable, Codable, Sendable, Identifiable {
    public var id: AssetID
    public var type: AssetType
    public var name: String
    public var description: String
    public var tags: [String]
    /// Exactly one has `isPrimary == true` (enforced by `normalized()`).
    public var references: [ReferenceSlot]
    /// Characters only (nil for places and objects).
    public var sheet: CharacterSheet?
    /// Bumped when the description or the primary reference's chosen image changes
    /// (PD §8.3 "asset changed"). Undo restores it; a number is never reused (high water).
    public var revision: Int
    public var revisionHighWater: Int

    public init(id: AssetID = AssetID(), type: AssetType, name: String, description: String = "",
                tags: [String] = [], references: [ReferenceSlot], sheet: CharacterSheet? = nil,
                revision: Int = 1, revisionHighWater: Int? = nil) {
        self.id = id
        self.type = type
        self.name = name
        self.description = description
        self.tags = tags
        self.references = references
        self.sheet = sheet
        self.revision = revision
        self.revisionHighWater = max(revisionHighWater ?? revision, revision)
    }

    /// A new asset with one primary slot ("Primary") and, for characters, the default sheet.
    /// Its sessions don't exist yet; `BookCommand.addAsset` creates them.
    public static func makeNew(type: AssetType, name: String) -> Asset {
        Asset(type: type, name: name, references: [ReferenceSlot(label: "Primary", isPrimary: true)],
              sheet: type == .character ? .makeDefault() : nil)
    }

    public var primary: ReferenceSlot? { references.first { $0.isPrimary } }

    /// Every session this asset owns, with its owner (slots first, then sheet items).
    public var ownedSessions: [(SessionID, SessionOwner)] {
        references.map { ($0.sessionID, SessionOwner.assetReference(id, $0.id)) }
            + (sheet?.items ?? []).map { ($0.sessionID, SessionOwner.sheetItem(id, $0.id)) }
    }

    /// Lane: model. Exactly one primary slot (the first if none or several), no sheet unless
    /// `type == .character`.
    public func normalized() -> Asset { self }

    /// Lane: model. `self` as edited from `old`: when the description or the primary slot's
    /// `chosen` differs (or a different slot is primary), `revision = max(old.revisionHighWater,
    /// revisionHighWater) + 1` and the high water follows; otherwise revision fields come from
    /// `old` unchanged.
    public func revised(from old: Asset) -> Asset { self }
}

// MARK: Mention tokens (A §4.3)

/// `⟦asset:<uuid>⟧` tokens in message text. Lane: model.
public enum MentionText {
    public static func token(for id: AssetID) -> String { "⟦asset:\(id.rawValue.uuidString)⟧" }

    /// Asset IDs mentioned in `text`, in first-occurrence order, no duplicates.
    public static func mentionedAssets(in text: String) -> [AssetID] { [] }

    /// Tokens replaced by the asset's current name (unknown IDs: by `fallback`, default "").
    public static func displayText(_ text: String, assets: [AssetID: Asset], fallback: String = "") -> String { text }

    /// Every token for `id` replaced by `plainText` (asset deletion turns mentions into plain text).
    public static func replacingMentions(of id: AssetID, with plainText: String, in text: String) -> String { text }

    /// Typed text → stored text: each `@Name` that exactly matches an asset name
    /// (case-insensitive, longest match first) becomes its token. Used when a typed prompt is
    /// sent without autocomplete picks.
    public static func tokenizing(_ typed: String, assets: [Asset]) -> String { typed }
}

// MARK: Where used (A §4.4)

public enum UsageReason: String, Hashable, Sendable, Codable, CaseIterable {
    /// The page's asset checklist ticks it (page-level, `box == nil`).
    case checklist
    /// A current-epoch message in the box's session mentions it.
    case mention
    /// The box's placed version was generated with it (`provenance.assetRevisions`).
    case placedImage
}

/// One place an asset is used: a page (`box == nil` for checklist use) or a page box.
public struct UsageSite: Hashable, Sendable {
    public var page: PageID
    public var box: BoxID?
    public var reasons: Set<UsageReason>
    public init(page: PageID, box: BoxID?, reasons: Set<UsageReason>) {
        self.page = page
        self.box = box
        self.reasons = reasons
    }
}

/// `[AssetID: Set<UsageSite>]`, rebuilt incrementally. Lane: model.
public struct UsageIndex: Hashable, Sendable {
    public init() {}
    public init(content: BookContent) {}

    /// Re-derive the entries for the listed pages (and the page boxes owning the listed
    /// sessions); pages no longer in `content` are dropped.
    public mutating func refresh(_ content: BookContent, pages: Set<PageID>, sessions: Set<SessionID>) {}

    /// Sites for `asset`, merged per (page, box), cover first then reading order, page-level
    /// entry before its boxes, boxes in template layer order.
    public func sites(for asset: AssetID, in content: BookContent) -> [UsageSite] { [] }

    public func isUsed(_ asset: AssetID) -> Bool { false }
}
