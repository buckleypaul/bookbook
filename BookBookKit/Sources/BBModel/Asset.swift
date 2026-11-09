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

    /// Exactly one primary slot (the first if none or several; a "Primary" slot is added if
    /// there are no slots), no sheet unless `type == .character`.
    public func normalized() -> Asset {
        var copy = self
        if copy.references.isEmpty {
            copy.references = [ReferenceSlot(label: "Primary", isPrimary: true)]
        } else {
            let first = copy.references.firstIndex { $0.isPrimary } ?? 0
            for i in copy.references.indices { copy.references[i].isPrimary = (i == first) }
        }
        if copy.type != .character { copy.sheet = nil }
        return copy
    }

    /// `self` as edited from `old`: when the description or the primary slot's `chosen` differs
    /// (or a different slot is primary), `revision = max(old.revisionHighWater,
    /// revisionHighWater) + 1` and the high water follows; otherwise revision fields come from
    /// `old` unchanged.
    public func revised(from old: Asset) -> Asset {
        var copy = self
        let changed = description != old.description || primary?.id != old.primary?.id
            || primary?.chosen != old.primary?.chosen
        if changed {
            let next = max(old.revisionHighWater, revisionHighWater) + 1
            copy.revision = next
            copy.revisionHighWater = next
        } else {
            copy.revision = old.revision
            copy.revisionHighWater = old.revisionHighWater
        }
        return copy
    }
}

// MARK: Mention tokens (A §4.3)

/// `⟦asset:<uuid>⟧` tokens in message text.
public enum MentionText {
    private static let open = "⟦asset:"
    private static let close: Character = "⟧"

    public static func token(for id: AssetID) -> String { "⟦asset:\(id.rawValue.uuidString)⟧" }

    /// Well-formed tokens found in text: range and asset.
    private static func tokens(in text: String) -> [(range: Range<String.Index>, id: AssetID)] {
        var out: [(range: Range<String.Index>, id: AssetID)] = []
        var from = text.startIndex
        while let start = text.range(of: open, range: from..<text.endIndex) {
            guard let end = text[start.upperBound...].firstIndex(of: close) else { break }
            if let uuid = UUID(uuidString: String(text[start.upperBound..<end])) {
                let after = text.index(after: end)
                out.append((range: start.lowerBound..<after, id: AssetID(rawValue: uuid)))
                from = after
            } else {
                from = start.upperBound
            }
        }
        return out
    }

    /// Asset IDs mentioned in `text`, in first-occurrence order, no duplicates.
    public static func mentionedAssets(in text: String) -> [AssetID] {
        var seen: Set<AssetID> = []
        return tokens(in: text).map(\.id).filter { seen.insert($0).inserted }
    }

    /// Replaces each token for which `replacement` returns non-nil.
    private static func replacing(_ text: String, _ replacement: (AssetID) -> String?) -> String {
        var out = ""
        var from = text.startIndex
        for (range, id) in tokens(in: text) {
            guard let r = replacement(id) else { continue }
            out += text[from..<range.lowerBound]
            out += r
            from = range.upperBound
        }
        out += text[from...]
        return out
    }

    /// Tokens replaced by the asset's current name (unknown IDs: by `fallback`, default "").
    public static func displayText(_ text: String, assets: [AssetID: Asset], fallback: String = "") -> String {
        replacing(text) { assets[$0]?.name ?? fallback }
    }

    /// Every token for `id` replaced by `plainText` (asset deletion turns mentions into plain text).
    public static func replacingMentions(of id: AssetID, with plainText: String, in text: String) -> String {
        replacing(text) { $0 == id ? plainText : nil }
    }

    /// Typed text -> stored text: each `@Name` that exactly matches an asset name
    /// (case-insensitive, longest match first, ending at a word boundary) becomes its token.
    /// Used when a typed prompt is sent without autocomplete picks.
    public static func tokenizing(_ typed: String, assets: [Asset]) -> String {
        let candidates = assets.filter { !$0.name.isEmpty }.sorted { $0.name.count > $1.name.count }
        guard !candidates.isEmpty, typed.contains("@") else { return typed }
        var out = ""
        var i = typed.startIndex
        while i < typed.endIndex {
            let ch = typed[i]
            let afterAt = typed.index(after: i)
            if ch == "@", i == typed.startIndex || !isWordCharacter(typed[typed.index(before: i)]),
               let (asset, end) = match(candidates, in: typed, from: afterAt) {
                out += token(for: asset.id)
                i = end
                continue
            }
            out.append(ch)
            i = afterAt
        }
        return out
    }

    private static func isWordCharacter(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }

    private static func match(_ candidates: [Asset], in text: String, from start: String.Index) -> (Asset, String.Index)? {
        for asset in candidates {
            guard let end = text.index(start, offsetBy: asset.name.count, limitedBy: text.endIndex) else { continue }
            guard text[start..<end].compare(asset.name, options: [.caseInsensitive]) == .orderedSame else { continue }
            if end < text.endIndex, isWordCharacter(text[end]) { continue }
            return (asset, end)
        }
        return nil
    }
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

/// `[AssetID: Set<UsageSite>]`, rebuilt incrementally.
public struct UsageIndex: Hashable, Sendable {
    /// Per page: asset -> (box, nil for page level) -> reasons. Only non-empty entries are kept,
    /// so an incrementally refreshed index equals a freshly built one.
    private var byPage: [PageID: [AssetID: [BoxID?: Set<UsageReason>]]] = [:]

    public init() {}

    public init(content: BookContent) {
        for id in content.pages.keys { rederive(id, in: content) }
    }

    /// Re-derive the entries for the listed pages (and the page boxes owning the listed
    /// sessions); pages no longer in `content` are dropped.
    public mutating func refresh(_ content: BookContent, pages: Set<PageID>, sessions: Set<SessionID>) {
        var affected = pages
        for sid in sessions {
            if case let .pageBox(page, _)? = content.sessions[sid]?.owner { affected.insert(page) }
        }
        for id in affected { rederive(id, in: content) }
    }

    private mutating func rederive(_ id: PageID, in content: BookContent) {
        guard let page = content.pages[id] else {
            byPage[id] = nil
            return
        }
        var found: [AssetID: [BoxID?: Set<UsageReason>]] = [:]
        for asset in page.assetChecklist { found[asset, default: [:]][nil, default: []].insert(.checklist) }
        for (boxID, slot) in page.images {
            guard let session = content.sessions[slot.sessionID] else { continue }
            for message in session.messages where message.epoch == session.resetEpoch {
                for asset in MentionText.mentionedAssets(in: message.text) {
                    found[asset, default: [:]][boxID, default: []].insert(.mention)
                }
            }
            if let placement = slot.placement,
               let revisions = session.version(placement.versionID)?.provenance?.assetRevisions {
                for asset in revisions.keys { found[asset, default: [:]][boxID, default: []].insert(.placedImage) }
            }
        }
        byPage[id] = found.isEmpty ? nil : found
    }

    /// Sites for `asset`, merged per (page, box), cover first then reading order, page-level
    /// entry before its boxes, boxes in template layer order.
    public func sites(for asset: AssetID, in content: BookContent) -> [UsageSite] {
        var order: [PageID] = [content.book.coverPageID]
        order += content.book.pageOrder.filter { $0 != content.book.coverPageID }
        let known = Set(order)
        order += byPage.keys.filter { !known.contains($0) }.sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
        var out: [UsageSite] = []
        for pageID in order {
            guard let entry = byPage[pageID]?[asset] else { continue }
            if let reasons = entry[nil] { out.append(UsageSite(page: pageID, box: nil, reasons: reasons)) }
            let layers = content.pages[pageID].flatMap { content.template(for: $0) }?.boxes.map(\.id) ?? []
            let boxes = entry.keys.compactMap { $0 }
            let ordered = layers.filter { boxes.contains($0) }
                + boxes.filter { !layers.contains($0) }.sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
            for box in ordered { out.append(UsageSite(page: pageID, box: box, reasons: entry[box] ?? [])) }
        }
        return out
    }

    public func isUsed(_ asset: AssetID) -> Bool {
        byPage.values.contains { $0[asset] != nil }
    }
}
