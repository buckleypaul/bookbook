import BBModel
import Foundation

/// What an image is in a request (A §7.3, §7.4, §7.8). The raw value is what provenance stores
/// as `SentReference.role` and names the image prompt's legend file (`legend-<role>.txt`).
public enum ReferenceRole: String, Hashable, Sendable, CaseIterable {
    /// The image being refined or region-edited (sent first).
    case base
    /// A version the user attached.
    case reference
    /// An asset's reference photo, sent only with that asset's own requests.
    case photo
    /// An asset's chosen image.
    case asset
    /// A style reference.
    case style
    /// The version a consistency check looks at (no legend: checks have their own prompt).
    case checked
}

/// Chooses and orders the reference images for a request (A §7.4). Deterministic, no AI call.
///
/// Two steps, so the queue can load bytes in between:
/// 1. `candidates(_:)` builds every image worth sending, in tier order, with the style-reference
///    cap applied (no bytes needed). Each asset in play contributes only its one chosen image.
/// 2. `select(_:byteCounts:limits:)` fills the model's image and byte budget in that order and
///    stops at the first image that doesn't fit; the rest are listed as omitted.
public enum ReferenceSelector {
    /// Priority tiers (A §7.4). Earlier tiers fill first; the tier order is the image order.
    public enum Tier: Int, Comparable, Hashable, Sendable, CaseIterable {
        /// The base image when refining or doing a region edit.
        case base = 1
        /// References the user attached ("same kitchen as page 4").
        case attached
        /// The chosen images of mentioned assets.
        case mentionedAsset
        /// The chosen images of checklist-only assets.
        case checklistAsset
        /// The first two style references.
        case style
        /// Style references beyond the first two: sent only with spare capacity.
        case spareStyle

        public static func < (lhs: Tier, rhs: Tier) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// One image that may be sent.
    public struct Candidate: Hashable, Sendable {
        public var ref: ImageRef
        /// `SentReference.role` is its raw value.
        public var role: ReferenceRole
        /// e.g. "Pip", "Style reference 3", "Reference v2".
        public var label: String
        public var tier: Tier
        /// Known for versions; nil for style references until the bytes are read.
        public var pixelSize: PixelSize?
        /// The asset this image shows (role `asset`).
        public var asset: AssetID?
        /// The version was imported as a photo of a real person (A §11).
        public var depictsRealPerson: Bool

        public init(ref: ImageRef, role: ReferenceRole, label: String, tier: Tier, pixelSize: PixelSize? = nil,
                    asset: AssetID? = nil, depictsRealPerson: Bool = false) {
            self.ref = ref
            self.role = role
            self.label = label
            self.tier = tier
            self.pixelSize = pixelSize
            self.asset = asset
            self.depictsRealPerson = depictsRealPerson
        }

        /// How provenance records it when sent.
        public var sentReference: SentReference { SentReference(image: ref, role: role.rawValue, label: label) }
    }

    /// An asset in play (A §7.3 step 1), with how it got there.
    public struct AssetInPlay: Hashable, Sendable {
        public var asset: Asset
        /// Mentioned (or the owner of an asset session) rather than checklist-only.
        public var mentioned: Bool
        /// The asset's image is not sent: it's the owner of the asset session being generated
        /// (when refining, the base image already carries it).
        public var excludesImage: Bool
        /// The cast line names the asset without its description: it's the owner of the asset
        /// session, whose request text is that description.
        public var omitsDescription: Bool

        public init(asset: Asset, mentioned: Bool, excludesImage: Bool = false, omitsDescription: Bool = false) {
            self.asset = asset
            self.mentioned = mentioned
            self.excludesImage = excludesImage
            self.omitsDescription = omitsDescription
        }
    }

    public struct Input: Sendable {
        public var base: Candidate?
        public var attached: [Candidate]
        /// In play order (mentioned first, then checklist-only).
        public var assets: [AssetInPlay]
        public var styleReferences: [ImageRef]
        /// Where the assets' chosen versions are looked up.
        public var sessions: [SessionID: Session]

        public init(base: Candidate? = nil, attached: [Candidate] = [], assets: [AssetInPlay] = [],
                    styleReferences: [ImageRef] = [], sessions: [SessionID: Session] = [:]) {
            self.base = base
            self.attached = attached
            self.assets = assets
            self.styleReferences = styleReferences
            self.sessions = sessions
        }
    }

    /// At most this many style references unless there's spare capacity (A §7.4 tier 5).
    public static let styleReferenceCap = 2

    /// Every image worth sending, in send order. Duplicated images keep their first (highest
    /// tier) entry. An asset with no chosen image (or whose chosen version is gone) sends nothing.
    public static func candidates(_ input: Input) -> [Candidate] {
        var out: [Candidate] = []
        if let base = input.base { out.append(base) }
        out += input.attached

        // Tiers 3 and 4: each asset's one chosen image.
        for entry in input.assets where !entry.excludesImage {
            let asset = entry.asset
            guard let chosen = asset.chosen, let v = input.sessions[asset.sessionID]?.version(chosen) else { continue }
            out.append(Candidate(ref: v.image, role: .asset, label: asset.name,
                                 tier: entry.mentioned ? .mentionedAsset : .checklistAsset,
                                 pixelSize: v.pixelSize, asset: asset.id,
                                 depictsRealPerson: v.depictsRealPerson == true))
        }

        // Tier 5 (and the spare tail).
        for (index, ref) in input.styleReferences.enumerated() {
            out.append(Candidate(ref: ref, role: .style, label: "Style reference \(index + 1)",
                                 tier: index < styleReferenceCap ? .style : .spareStyle))
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
            /// `SentReference` for provenance: label "Pip (over the limit)".
            public var sentReference: SentReference {
                SentReference(image: candidate.ref, role: candidate.role.rawValue, label: "\(candidate.label) (\(reason.rawValue))")
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

    /// "Left out: Granny Oak; style reference 3." for Version details and the
    /// pre-send report; nil when nothing was left out. Reads `Provenance.referencesOmitted` labels.
    public static func leftOutSummary(_ omitted: [SentReference]) -> String? {
        guard !omitted.isEmpty else { return nil }
        let items = omitted.map { reference -> String in
            var label = reference.label
            for reason in OmissionReason.allCases where label.hasSuffix(" (\(reason.rawValue))") {
                label.removeLast(reason.rawValue.count + 3)
            }
            // Asset labels start with a name; the others ("Style reference 3") read lower-case mid-sentence.
            if reference.role != ReferenceRole.asset.rawValue, let first = label.first {
                label = first.lowercased() + label.dropFirst()
            }
            return label
        }
        return "Left out: " + items.joined(separator: "; ") + "."
    }
}
