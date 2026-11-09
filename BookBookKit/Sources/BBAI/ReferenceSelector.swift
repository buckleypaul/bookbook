import BBModel
import Foundation

/// Chooses and orders the reference images for a request (A §7.4). Deterministic, no AI call.
///
/// Two steps, so the queue can load bytes in between:
/// 1. `candidates(_:)` builds every image worth sending, in tier order, with the per-asset caps,
///    sheet matching and the style-reference cap applied (no bytes needed).
/// 2. `select(_:byteCounts:limits:)` fills the model's image and byte budget in that order and
///    stops at the first image that doesn't fit; the rest are listed as omitted.
public enum ReferenceSelector {
    /// Priority tiers (A §7.4). Earlier tiers fill first; the tier order is the image order.
    public enum Tier: Int, Comparable, Hashable, Sendable, CaseIterable {
        /// The base image when refining or doing a region edit.
        case base = 1
        /// References the user attached ("same kitchen as page 4").
        case attached
        /// Primary references of mentioned assets (and the owner of an asset session).
        case mentionedPrimary
        /// Primary references of checklist-only assets.
        case checklistPrimary
        /// The first two style references.
        case style
        /// Matching sheet items (expression, then view, per character).
        case sheetItem
        /// Other reference slots of the assets in play (places only, by the caps).
        case otherSlot
        /// Style references beyond the first two: sent only with spare capacity.
        case spareStyle

        public static func < (lhs: Tier, rhs: Tier) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// One image that may be sent.
    public struct Candidate: Hashable, Sendable {
        public var ref: ImageRef
        /// `base`, `reference` (attached), `asset` or `style` (`SentReference.role`).
        public var role: String
        /// e.g. "Pip – sleepy expression", "Style reference 3", "Reference v2".
        public var label: String
        public var tier: Tier
        /// Known for versions; nil for style references until the bytes are read.
        public var pixelSize: PixelSize?
        /// The asset this image shows (role `asset`).
        public var asset: AssetID?
        /// What it shows of the asset, e.g. "primary reference", "sleepy expression".
        public var detail: String?
        /// The version was imported as a photo of a real person (A §11).
        public var depictsRealPerson: Bool

        public init(ref: ImageRef, role: String, label: String, tier: Tier, pixelSize: PixelSize? = nil,
                    asset: AssetID? = nil, detail: String? = nil, depictsRealPerson: Bool = false) {
            self.ref = ref
            self.role = role
            self.label = label
            self.tier = tier
            self.pixelSize = pixelSize
            self.asset = asset
            self.detail = detail
            self.depictsRealPerson = depictsRealPerson
        }
    }

    /// An asset in play (A §7.3 step 1), with how it got there.
    public struct AssetInPlay: Hashable, Sendable {
        public var asset: Asset
        /// Mentioned (or the owner of an asset session) rather than checklist-only.
        public var mentioned: Bool
        /// Only the primary reference is wanted (the owner of an asset session).
        public var primaryOnly: Bool
        /// A slot never sent as a reference (the slot an asset session is generating).
        public var excludedSlot: UUID?

        public init(asset: Asset, mentioned: Bool, primaryOnly: Bool = false, excludedSlot: UUID? = nil) {
            self.asset = asset
            self.mentioned = mentioned
            self.primaryOnly = primaryOnly
            self.excludedSlot = excludedSlot
        }
    }

    public struct Input: Sendable {
        public var base: Candidate?
        public var attached: [Candidate]
        /// In play order (mentioned first, then checklist-only).
        public var assets: [AssetInPlay]
        public var styleReferences: [ImageRef]
        /// The current message (names, not tokens) plus the story text when it's included.
        public var matchText: String
        /// Where slot and sheet-item versions are looked up.
        public var sessions: [SessionID: Session]

        public init(base: Candidate? = nil, attached: [Candidate] = [], assets: [AssetInPlay] = [],
                    styleReferences: [ImageRef] = [], matchText: String = "", sessions: [SessionID: Session] = [:]) {
            self.base = base
            self.attached = attached
            self.assets = assets
            self.styleReferences = styleReferences
            self.matchText = matchText
            self.sessions = sessions
        }
    }

    /// At most this many style references unless there's spare capacity (A §7.4 tier 5).
    public static let styleReferenceCap = 2

    /// Every image worth sending, in send order. Duplicated images keep their first (highest
    /// tier) entry. Unchosen slots and sheet items (or ones whose version is gone) are skipped;
    /// locked items are kept (locked means "don't regenerate", Phase 10 decision).
    public static func candidates(_ input: Input, synonyms: SheetSynonyms = .bundled) -> [Candidate] {
        var out: [Candidate] = []
        if let base = input.base { out.append(base) }
        out += input.attached

        func version(_ session: SessionID, _ chosen: VersionID?) -> Version? {
            chosen.flatMap { input.sessions[session]?.version($0) }
        }
        func assetCandidate(_ asset: Asset, _ version: Version, detail: String, tier: Tier) -> Candidate {
            Candidate(ref: version.image, role: "asset", label: "\(asset.name) – \(detail)", tier: tier,
                      pixelSize: version.pixelSize, asset: asset.id, detail: detail,
                      depictsRealPerson: version.depictsRealPerson == true)
        }

        // Tiers 3 and 4: primaries.
        for entry in input.assets {
            let asset = entry.asset
            guard let primary = asset.primary, primary.id != entry.excludedSlot,
                  let v = version(primary.sessionID, primary.chosen) else { continue }
            out.append(assetCandidate(asset, v, detail: "primary reference",
                                      tier: entry.mentioned ? .mentionedPrimary : .checklistPrimary))
        }

        // Tier 5 (and the spare tail).
        for (index, ref) in input.styleReferences.enumerated() {
            out.append(Candidate(ref: ref, role: "style", label: "Style reference \(index + 1)",
                                 tier: index < styleReferenceCap ? .style : .spareStyle))
        }

        // Tier 6: matching sheet items. Characters: 1 expression, then 1 view.
        for entry in input.assets where !entry.primaryOnly && entry.asset.type == .character {
            let asset = entry.asset
            let chosen = (asset.sheet?.items ?? []).compactMap { item -> (SheetItem, Version)? in
                version(item.sessionID, item.chosen).map { (item, $0) }
            }
            let expressions = chosen.compactMap { pair -> (String, (SheetItem, Version))? in
                if case let .expression(name) = pair.0.kind { return (name, pair) }
                return nil
            }
            if let name = synonyms.matchExpression(in: input.matchText, among: expressions.map(\.0)),
               let (_, v) = expressions.first(where: { $0.0 == name })?.1 {
                out.append(assetCandidate(asset, v, detail: "\(displayName(expression: name)) expression", tier: .sheetItem))
            }
            let views = chosen.compactMap { pair -> (SheetView, Version)? in
                if case let .view(view) = pair.0.kind { return (view, pair.1) }
                return nil
            }
            if let view = synonyms.matchView(in: input.matchText, among: views.map(\.0)),
               let v = views.first(where: { $0.0 == view })?.1 {
                out.append(assetCandidate(asset, v, detail: "\(displayName(view: view)) view", tier: .sheetItem))
            }
        }

        // Tier 7: other slots. Places get one (a slot whose label the text names, else the first);
        // characters and objects get none (per-asset caps).
        let textTokens = SheetSynonyms.tokens(input.matchText)
        for entry in input.assets where !entry.primaryOnly && entry.asset.type == .place {
            let asset = entry.asset
            let others = asset.references.filter { !$0.isPrimary && $0.id != entry.excludedSlot }
                .compactMap { slot in version(slot.sessionID, slot.chosen).map { (slot, $0) } }
            let named = others.first { pair in
                let label = SheetSynonyms.tokens(pair.0.label)
                return !label.isEmpty && SheetSynonyms.position(of: label, in: textTokens) != nil
            }
            if let (slot, v) = named ?? others.first {
                out.append(assetCandidate(asset, v, detail: slot.label.lowercased(), tier: .otherSlot))
            }
        }

        // Stable by tier; duplicates keep the first entry.
        var seen = Set<ImageRef>()
        return out.enumerated()
            .sorted { ($0.element.tier, $0.offset) < ($1.element.tier, $1.offset) }
            .map(\.element)
            .filter { seen.insert($0.ref).inserted }
    }

    // MARK: Budget

    public struct Limits: Hashable, Sendable {
        public var maxImages: Int
        public var maxImageBytes: Int
        public var maxTotalBytes: Int
        public init(maxImages: Int, maxImageBytes: Int, maxTotalBytes: Int) {
            self.maxImages = maxImages
            self.maxImageBytes = maxImageBytes
            self.maxTotalBytes = maxTotalBytes
        }
    }

    public enum OmissionReason: String, Hashable, Sendable, CaseIterable {
        case overLimit = "over the limit"
        case fileMissing = "file missing"
        case tooLarge = "too large"
    }

    public struct Selection: Hashable, Sendable {
        public var sent: [Candidate]
        public var omitted: [Omitted]
        public var bytes: Int

        public struct Omitted: Hashable, Sendable {
            public var candidate: Candidate
            public var reason: OmissionReason
            /// `SentReference` for provenance: label "Pip – sleepy expression (over the limit)".
            public var sentReference: SentReference {
                SentReference(image: candidate.ref, role: candidate.role, label: "\(candidate.label) (\(reason.rawValue))")
            }
        }
    }

    /// Fills the budget in candidate order. A missing or individually too-large image is skipped;
    /// the first image that would pass the image count or total byte budget stops selection, and
    /// it and everything after it are omitted "over the limit". `byteCounts` has the size of each
    /// image whose bytes are available (absent = file missing).
    public static func select(_ candidates: [Candidate], byteCounts: [ImageRef: Int], limits: Limits) -> Selection {
        var selection = Selection(sent: [], omitted: [], bytes: 0)
        var stopped = false
        for candidate in candidates {
            func omit(_ reason: OmissionReason) { selection.omitted.append(.init(candidate: candidate, reason: reason)) }
            if stopped { omit(.overLimit); continue }
            guard let size = byteCounts[candidate.ref] else { omit(.fileMissing); continue }
            if size > limits.maxImageBytes { omit(.tooLarge); continue }
            if selection.sent.count >= limits.maxImages || selection.bytes + size > limits.maxTotalBytes {
                stopped = true
                omit(.overLimit)
                continue
            }
            selection.bytes += size
            selection.sent.append(candidate)
        }
        return selection
    }

    // MARK: Report wording

    /// "Left out: Granny Oak – sleepy expression; style reference 3." for Version details and the
    /// pre-send report; nil when nothing was left out. Reads `Provenance.referencesOmitted` labels.
    public static func leftOutSummary(_ omitted: [SentReference]) -> String? {
        guard !omitted.isEmpty else { return nil }
        let items = omitted.map { reference -> String in
            var label = reference.label
            for reason in OmissionReason.allCases where label.hasSuffix(" (\(reason.rawValue))") {
                label.removeLast(reason.rawValue.count + 3)
            }
            // Asset labels start with a name; the others ("Style reference 3") read lower-case mid-sentence.
            if reference.role != "asset", let first = label.first {
                label = first.lowercased() + label.dropFirst()
            }
            return label
        }
        return "Left out: " + items.joined(separator: "; ") + "."
    }

    /// "three-quarter", "side".
    public static func displayName(view: SheetView) -> String {
        switch view {
        case .front: "front"
        case .threeQuarter: "three-quarter"
        case .side: "side"
        case .back: "back"
        }
    }

    static func displayName(expression name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

// MARK: - Sheet matching

/// The bundled synonym table (`Resources/Prompts/sheet-synonyms.json`) and the text matching used
/// for sheet items (A §7.4).
public struct SheetSynonyms: Hashable, Sendable {
    /// Built-in expression name → words and phrases.
    public var expressions: [String: [String]]
    public var views: [SheetView: [String]]

    public init(expressions: [String: [String]], views: [SheetView: [String]]) {
        self.expressions = expressions
        self.views = views
    }

    private struct File: Decodable {
        var expressions: [String: [String]]
        var views: [String: [String]]
    }

    public static let bundled: SheetSynonyms = {
        guard let url = Bundle.module.resourceURL?.appendingPathComponent("Prompts/sheet-synonyms.json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else {
            return SheetSynonyms(expressions: [:], views: [:])
        }
        var views: [SheetView: [String]] = [:]
        for (key, words) in file.views { if let view = SheetView(rawValue: key) { views[view] = words } }
        return SheetSynonyms(expressions: file.expressions, views: views)
    }()

    /// The expression (one of `names`) the text asks for: its own name (and simple inflections)
    /// or, for built-in names, a synonym. The earliest match in the text wins; ties go to the
    /// order of `names`. Case-insensitive; the returned value is the element of `names`.
    public func matchExpression(in text: String, among names: [String]) -> String? {
        let tokens = Self.tokens(text)
        var best: (position: Int, name: String)?
        for name in names {
            let key = ReferenceSelector.displayName(expression: name)
            let phrases = Self.phrases(for: [key] + (expressions[key] ?? []))
            guard let position = phrases.compactMap({ Self.position(of: $0, in: tokens) }).min() else { continue }
            if best == nil || position < best!.position { best = (position, name) }
        }
        return best?.name
    }

    /// The view (one of `available`) the text asks for; with no match, three-quarter if available.
    public func matchView(in text: String, among available: [SheetView]) -> SheetView? {
        let tokens = Self.tokens(text)
        var best: (position: Int, view: SheetView)?
        for view in available {
            let phrases = Self.phrases(for: views[view] ?? [])
            guard let position = phrases.compactMap({ Self.position(of: $0, in: tokens) }).min() else { continue }
            if best == nil || position < best!.position { best = (position, view) }
        }
        return best?.view ?? (available.contains(.threeQuarter) ? .threeQuarter : nil)
    }

    /// Lower-cased words (letters and digits); everything else separates.
    static func tokens(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// Token sequences for the entries; single words also get their simple inflections.
    static func phrases(for entries: [String]) -> [[String]] {
        var out: [[String]] = []
        for entry in entries {
            let words = tokens(entry)
            guard let last = words.last else { continue }
            for form in inflections(of: last) { out.append(words.dropLast() + [form]) }
        }
        return out
    }

    /// The word plus -s, -ing, -ed, -y, and the e-drop forms ("smile" → "smiling", "smiled", "smiley").
    static func inflections(of word: String) -> [String] {
        var forms = [word, word + "s", word + "es", word + "ing", word + "ed", word + "y"]
        if word.hasSuffix("e"), word.count > 2 {
            let stem = String(word.dropLast())
            forms += [stem + "ing", stem + "ed", stem + "y", word + "d"]
        }
        return forms
    }

    /// Index of the first occurrence of `phrase` in `tokens`.
    static func position(of phrase: [String], in tokens: [String]) -> Int? {
        guard !phrase.isEmpty, phrase.count <= tokens.count else { return nil }
        for start in 0...(tokens.count - phrase.count) where Array(tokens[start..<start + phrase.count]) == phrase {
            return start
        }
        return nil
    }
}
