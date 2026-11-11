import Foundation

// A §4.2 `Asset`, A §4.3 mention tokens, A §4.4 asset changed and where-used.
// Simplified 2026-11-11: an asset has exactly one image, made in one session (the multi-slot
// references and the character sheet were removed). Old files still decode: see `init(from:)`.
// Tags were removed the same day (they were never used); an old `tags` key is ignored.
// Reference photo added 2026-11-11: an optional photo (e.g. of the real person) that Generate
// sends with the description so the illustration is based on it. Never sent with page requests.

public enum AssetType: String, Codable, Sendable, CaseIterable {
    case character, place, object
}

/// A photo the asset's Generate is based on (PD §8.3): sent only with the asset's own requests,
/// never with page or cover requests (pages get the illustration it produced).
public struct AssetReferencePhoto: Hashable, Codable, Sendable {
    public var image: ImageRef
    public var pixelSize: PixelSize?
    /// The user's answer to "Is this a photo of a real person?" (A §11).
    public var depictsRealPerson: Bool

    public init(image: ImageRef, pixelSize: PixelSize? = nil, depictsRealPerson: Bool) {
        self.image = image
        self.pixelSize = pixelSize
        self.depictsRealPerson = depictsRealPerson
    }
}

public struct Asset: Hashable, Sendable, Identifiable {
    public var id: AssetID
    public var type: AssetType
    public var name: String
    public var description: String
    /// The session that makes the asset's one image (owner `.asset(id)`).
    public var sessionID: SessionID
    /// The version of `sessionID` used as the asset's image; nil = nothing chosen yet (not sent).
    public var chosen: VersionID?
    /// Bumped when the description or the chosen image changes (PD §8.3 "asset changed").
    /// Undo restores it; a number is never reused (high water).
    public var revision: Int
    public var revisionHighWater: Int
    /// The photo Generate bases the image on; nil = generate from the description alone.
    /// Changing it doesn't bump `revision`: pages only see the image it produces.
    public var referencePhoto: AssetReferencePhoto?

    public init(id: AssetID = AssetID(), type: AssetType, name: String, description: String = "",
                sessionID: SessionID = SessionID(), chosen: VersionID? = nil,
                revision: Int = 1, revisionHighWater: Int? = nil, referencePhoto: AssetReferencePhoto? = nil) {
        self.id = id
        self.type = type
        self.name = name
        self.description = description
        self.sessionID = sessionID
        self.chosen = chosen
        self.revision = revision
        self.revisionHighWater = max(revisionHighWater ?? revision, revision)
        self.referencePhoto = referencePhoto
    }

    /// A new asset. Its session doesn't exist yet; `BookCommand.addAsset` creates it.
    public static func makeNew(type: AssetType, name: String) -> Asset {
        Asset(type: type, name: name)
    }

    /// The session this asset owns.
    public var owner: SessionOwner { .asset(id) }

    /// `self` as edited from `old`: when the description or `chosen` differs,
    /// `revision = max(old.revisionHighWater, revisionHighWater) + 1` and the high water
    /// follows; otherwise revision fields come from `old` unchanged.
    public func revised(from old: Asset) -> Asset {
        var copy = self
        let changed = description != old.description || chosen != old.chosen
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

extension Asset: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, type, name, description, sessionID, chosen, revision, revisionHighWater, referencePhoto
        /// Legacy (before 2026-11-11): `[ReferenceSlot]`; `sheet` is ignored.
        case references
    }

    private struct LegacySlot: Decodable {
        var isPrimary: Bool
        var sessionID: SessionID
        var chosen: VersionID?
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(AssetID.self, forKey: .id)
        type = try c.decode(AssetType.self, forKey: .type)
        name = try c.decode(String.self, forKey: .name)
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        if let sid = try c.decodeIfPresent(SessionID.self, forKey: .sessionID) {
            sessionID = sid
            chosen = try c.decodeIfPresent(VersionID.self, forKey: .chosen)
        } else {
            // Legacy: keep the primary slot (or the first); other slots and the sheet are dropped.
            let slots = try c.decodeIfPresent([LegacySlot].self, forKey: .references) ?? []
            let keep = slots.first { $0.isPrimary } ?? slots.first
            sessionID = keep?.sessionID ?? SessionID()
            chosen = keep?.chosen
        }
        revision = try c.decodeIfPresent(Int.self, forKey: .revision) ?? 1
        revisionHighWater = max(try c.decodeIfPresent(Int.self, forKey: .revisionHighWater) ?? revision, revision)
        referencePhoto = try c.decodeIfPresent(AssetReferencePhoto.self, forKey: .referencePhoto)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(type, forKey: .type)
        try c.encode(name, forKey: .name)
        try c.encode(description, forKey: .description)
        try c.encode(sessionID, forKey: .sessionID)
        try c.encodeIfPresent(chosen, forKey: .chosen)
        try c.encode(revision, forKey: .revision)
        try c.encode(revisionHighWater, forKey: .revisionHighWater)
        try c.encodeIfPresent(referencePhoto, forKey: .referencePhoto)
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
        var order = content.pageIDsCoverFirst
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
