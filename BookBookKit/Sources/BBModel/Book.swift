import Foundation

// Core types (architecture.md §4.2). Phase 2 keeps schema version 1 and may still break it
// until Phase 3 (implementation-plan.md Phase 2 "Risks").

/// `book.json`.
public struct Book: Hashable, Codable, Sendable {
    public static let currentSchemaVersion = 1

    public var id: BookID
    public var schemaVersion: Int
    public var title: String
    public var author: String
    public var createdAt: Date
    public var modifiedAt: Date
    /// Reading order of story pages, excluding the cover.
    public var pageOrder: [PageID]
    public var coverPageID: PageID
    public var budget: Decimal?
    public var acknowledgements: Acknowledgements

    public init(id: BookID = BookID(), schemaVersion: Int = Book.currentSchemaVersion, title: String,
                author: String = "", createdAt: Date, modifiedAt: Date, pageOrder: [PageID],
                coverPageID: PageID, budget: Decimal? = nil, acknowledgements: Acknowledgements = .init()) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.title = title
        self.author = author
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.pageOrder = pageOrder
        self.coverPageID = coverPageID
        self.budget = budget
        self.acknowledgements = acknowledgements
    }
}

/// Notices the user has acknowledged, e.g. the real-person-photo notice per provider.
public struct Acknowledgements: Hashable, Codable, Sendable {
    public var realPersonPhotoNotice: [ProviderID]

    public init(realPersonPhotoNotice: [ProviderID] = []) {
        self.realPersonPhotoNotice = realPersonPhotoNotice
    }
}

/// `style.json`.
public struct StyleGuide: Hashable, Codable, Sendable {
    public static let defaultNegativeGuidance = "no text, letters or words in the image"

    public var presetID: String?
    public var visualDescription: String
    public var styleReferences: [ImageRef]
    public var negativeGuidance: String
    public var visualRevision: Int
    public var typography: Typography
    public var pageSetup: PageSetup
    public var pageNumbers: PageNumberStyle

    public init(presetID: String? = nil, visualDescription: String = "", styleReferences: [ImageRef] = [],
                negativeGuidance: String = StyleGuide.defaultNegativeGuidance, visualRevision: Int = 0,
                typography: Typography = .default, pageSetup: PageSetup = .letterPortrait,
                pageNumbers: PageNumberStyle = .init()) {
        self.presetID = presetID
        self.visualDescription = visualDescription
        self.styleReferences = styleReferences
        self.negativeGuidance = negativeGuidance
        self.visualRevision = visualRevision
        self.typography = typography
        self.pageSetup = pageSetup
        self.pageNumbers = pageNumbers
    }
}

/// An installed or imported font, referenced by PostScript name (A §8.3).
public struct FontRef: Hashable, Codable, Sendable {
    public var postScriptName: String
    public init(postScriptName: String) { self.postScriptName = postScriptName }
}

public struct Typography: Hashable, Codable, Sendable {
    public var bodyFont: FontRef
    public var titleFont: FontRef
    /// Body size in points.
    public var bodySize: Double
    public var color: RGBA
    /// Line height multiple (1.0 = the font's natural line height).
    public var lineSpacing: Double
    public var alignment: TextAlignment

    public init(bodyFont: FontRef, titleFont: FontRef, bodySize: Double, color: RGBA,
                lineSpacing: Double, alignment: TextAlignment) {
        self.bodyFont = bodyFont
        self.titleFont = titleFont
        self.bodySize = bodySize
        self.color = color
        self.lineSpacing = lineSpacing
        self.alignment = alignment
    }

    /// Avenir Next (decided 2026-11-08 for the Phase 2 slice; the full form comes in Phases 4/7).
    public static let `default` = Typography(
        bodyFont: FontRef(postScriptName: "AvenirNext-Regular"),
        titleFont: FontRef(postScriptName: "AvenirNext-Bold"),
        bodySize: 20, color: .black, lineSpacing: 1.2, alignment: .leading)
}

public enum Orientation: String, Codable, Sendable {
    /// `.square` is used by square sizes (width == height); it is not a choice for others.
    case portrait, landscape, square
}

/// Page size presets (PD §8.2). Base sizes are portrait (width ≤ height), in points.
public enum PageSizePreset: String, Codable, Sendable, CaseIterable {
    case usLetter, a4, halfLetter, a5, square8, square8_5, eightByTen, tenByEight, custom

    /// Size in points as named (`tenByEight` is landscape by name); nil for `.custom`.
    /// Phase 7 lane: implement.
    public var baseSize: PointSize? { nil }
    /// Menu title ("US Letter", "A4", "5.5 × 8.5 in", …). Phase 7 lane: implement.
    public var displayName: String { rawValue }
    /// Prints as a booklet on Letter / A4 paper (PD §8.2): `halfLetter`, `a5`.
    public var isBookletSize: Bool { self == .halfLetter || self == .a5 }
}

/// The visual part of the style guide: the fields whose change bumps `visualRevision` (A §4.1).
/// `presetID` is carried along but doesn't bump by itself.
public struct StyleVisual: Hashable, Codable, Sendable {
    public var presetID: String?
    public var visualDescription: String
    public var styleReferences: [ImageRef]
    public var negativeGuidance: String

    public init(presetID: String? = nil, visualDescription: String = "", styleReferences: [ImageRef] = [],
                negativeGuidance: String = StyleGuide.defaultNegativeGuidance) {
        self.presetID = presetID
        self.visualDescription = visualDescription
        self.styleReferences = styleReferences
        self.negativeGuidance = negativeGuidance
    }
}

extension StyleGuide {
    public var visual: StyleVisual {
        StyleVisual(presetID: presetID, visualDescription: visualDescription,
                    styleReferences: styleReferences, negativeGuidance: negativeGuidance)
    }

    /// Returns a copy with `visual` applied; `visualRevision` goes up by one when the
    /// description, references or negative guidance change (A §4.1). Phase 7 lane: implement.
    public func applying(_ visual: StyleVisual) -> StyleGuide { self }
}

/// Page setup, in points. Phase 2 only uses Letter portrait with no bleed.
public struct PageSetup: Hashable, Codable, Sendable {
    /// Trim size as laid out (orientation already applied).
    public var trimSize: PointSize
    public var orientation: Orientation
    public var margins: EdgeInsetsPt
    public var bleedEnabled: Bool
    /// Bleed amount in points (default 0.125 in = 9 pt), used only when `bleedEnabled`.
    public var bleedAmount: Double
    /// Which preset `trimSize` came from (Phase 7). Files without it decode as `.usLetter`
    /// when the trim is 612×792 (either orientation), else `.custom`. Phase 7 lane: decoder.
    public var sizePreset: PageSizePreset

    public init(trimSize: PointSize, orientation: Orientation, margins: EdgeInsetsPt,
                bleedEnabled: Bool = false, bleedAmount: Double = 9, sizePreset: PageSizePreset = .custom) {
        self.trimSize = trimSize
        self.orientation = orientation
        self.margins = margins
        self.bleedEnabled = bleedEnabled
        self.bleedAmount = bleedAmount
        self.sizePreset = sizePreset
    }

    /// A copy using `preset` in `orientation` (swapping the base size for landscape; square
    /// sizes always get `.square`). Margins and bleed are kept. For `.custom`, `customSize`
    /// is used as given and the orientation is derived from it. Phase 7 lane: implement.
    public func applying(preset: PageSizePreset, orientation: Orientation, customSize: PointSize? = nil) -> PageSetup { self }

    public static let letterPortrait = PageSetup(
        trimSize: PointSize(width: 612, height: 792), orientation: .portrait,
        margins: EdgeInsetsPt(all: 36), sizePreset: .usLetter)
}

/// Where page numbers sit on a page (PD §8.2). "Outer"/"inner" depend on the physical side:
/// outer is the left edge of a left-hand page and the right edge of a right-hand page.
public enum PageNumberPosition: String, Codable, Sendable, CaseIterable {
    case bottomCenter, bottomOuter, bottomInner, topCenter, topOuter, topInner
}

/// Page number style (PD §8.2, A §8.1, Phase 5). Numbers are positional: physical position
/// `p` (story page 1 is position 1, the cover is 0) shows `startNumber + p - 1`. Skipped pages
/// keep their number; it just isn't drawn. The cover is never numbered.
///
/// Decoding tolerates the Phase 2 shape (`{"enabled": …}` only): missing keys take defaults.
public struct PageNumberStyle: Hashable, Codable, Sendable {
    public var enabled: Bool
    public var position: PageNumberPosition
    /// nil = the style's body font.
    public var fontFamily: String?
    public var size: Double
    /// nil = the typography colour.
    public var color: RGBA?
    public var startNumber: Int
    /// Skip pages whose template has a front-matter `PageRole` (title, dedication, belongs-to).
    public var skipFrontMatter: Bool
    /// Specific pages to skip.
    public var skippedPages: Set<PageID>

    public init(enabled: Bool = false, position: PageNumberPosition = .bottomCenter,
                fontFamily: String? = nil, size: Double = 12, color: RGBA? = nil,
                startNumber: Int = 1, skipFrontMatter: Bool = true, skippedPages: Set<PageID> = []) {
        self.enabled = enabled
        self.position = position
        self.fontFamily = fontFamily
        self.size = size
        self.color = color
        self.startNumber = startNumber
        self.skipFrontMatter = skipFrontMatter
        self.skippedPages = skippedPages
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, position, fontFamily, size, color, startNumber, skipFrontMatter, skippedPages
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PageNumberStyle()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        position = try c.decodeIfPresent(PageNumberPosition.self, forKey: .position) ?? d.position
        fontFamily = try c.decodeIfPresent(String.self, forKey: .fontFamily)
        size = try c.decodeIfPresent(Double.self, forKey: .size) ?? d.size
        color = try c.decodeIfPresent(RGBA.self, forKey: .color)
        startNumber = try c.decodeIfPresent(Int.self, forKey: .startNumber) ?? d.startNumber
        skipFrontMatter = try c.decodeIfPresent(Bool.self, forKey: .skipFrontMatter) ?? d.skipFrontMatter
        skippedPages = try c.decodeIfPresent(Set<PageID>.self, forKey: .skippedPages) ?? d.skippedPages
    }
}

/// What a template is for, beyond its geometry (Phase 5). Front-matter roles are skipped by
/// page numbering when `PageNumberStyle.skipFrontMatter` is on.
public enum PageRole: String, Codable, Sendable, CaseIterable {
    case titlePage, dedication, belongsTo, theEnd
    public var isFrontMatter: Bool { self != .theEnd }
}

// MARK: - Templates

public enum TemplateKind: String, Codable, Sendable {
    case single, spread, cover
}

/// `templates/<id>.json`.
public struct Template: Hashable, Codable, Sendable, Identifiable {
    public var id: TemplateID
    public var name: String
    public var kind: TemplateKind
    /// Array order = layer order (first is drawn first).
    public var boxes: [Box]
    /// Front/back-matter role (title page, dedication, …); nil for ordinary story layouts.
    public var pageRole: PageRole?

    public init(id: TemplateID = TemplateID(), name: String, kind: TemplateKind, boxes: [Box],
                pageRole: PageRole? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.boxes = boxes
        self.pageRole = pageRole
    }

    public func box(_ id: BoxID) -> Box? { boxes.first { $0.id == id } }
    public var imageBoxes: [Box] { boxes.filter { $0.content == .image } }
    public var textBoxes: [Box] { boxes.filter { if case .text = $0.content { true } else { false } } }
}

public struct Box: Hashable, Codable, Sendable, Identifiable {
    public var id: BoxID
    public var frame: NormalizedRect
    public var rotationDegrees: Double
    /// Points.
    public var cornerRadius: Double
    public var bleedEdges: EdgeSet
    public var content: BoxContentKind
    public var role: BoxRole?

    public init(id: BoxID = BoxID(), frame: NormalizedRect, rotationDegrees: Double = 0, cornerRadius: Double = 0,
                bleedEdges: EdgeSet = [], content: BoxContentKind, role: BoxRole? = nil) {
        self.id = id
        self.frame = frame
        self.rotationDegrees = rotationDegrees
        self.cornerRadius = cornerRadius
        self.bleedEdges = bleedEdges
        self.content = content
        self.role = role
    }
}

public enum BoxContentKind: Hashable, Codable, Sendable {
    case image
    case text(TextBoxStyle)
}

/// Per-box text overrides layered on the style guide.
public struct TextBoxStyle: Hashable, Codable, Sendable {
    /// Inset of the text inside the box, in points.
    public var padding: Double
    /// Background panel colour, or nil for none.
    public var background: RGBA?
    /// Font size override in points (Phase 6). Layered between the style guide (below) and a
    /// run's own `size` (above). nil = the style guide's size for the box's role.
    public var fontSize: Double?
    /// Alignment override (Phase 6). A paragraph's own `alignment` still wins.
    public var alignment: TextAlignment?
    /// Text colour override (Phase 6). A run's own `color` still wins.
    public var color: RGBA?

    public init(padding: Double = 0, background: RGBA? = nil, fontSize: Double? = nil,
                alignment: TextAlignment? = nil, color: RGBA? = nil) {
        self.padding = padding
        self.background = background
        self.fontSize = fontSize
        self.alignment = alignment
        self.color = color
    }
}

public enum BoxRole: String, Codable, Sendable {
    case title, author, pageNumberSlot
}

// MARK: - Pages

public enum PageKind: String, Codable, Sendable {
    case story, cover
}

/// `pages/<id>.json`. The cover is a `Page` with kind `.cover`.
public struct Page: Hashable, Codable, Sendable, Identifiable {
    public var id: PageID
    public var kind: PageKind
    public var templateID: TemplateID
    public var text: [BoxID: RichText]
    public var images: [BoxID: ImageSlot]
    public var assetChecklist: [AssetID]
    public var isDone: Bool

    public init(id: PageID = PageID(), kind: PageKind, templateID: TemplateID, text: [BoxID: RichText] = [:],
                images: [BoxID: ImageSlot] = [:], assetChecklist: [AssetID] = [], isDone: Bool = false) {
        self.id = id
        self.kind = kind
        self.templateID = templateID
        self.text = text
        self.images = images
        self.assetChecklist = assetChecklist
        self.isDone = isDone
    }
}

public struct ImageSlot: Hashable, Codable, Sendable {
    public var sessionID: SessionID
    /// nil = empty box.
    public var placement: ImagePlacement?
    public var acknowledged: FlagBaseline

    public init(sessionID: SessionID, placement: ImagePlacement? = nil, acknowledged: FlagBaseline = .init()) {
        self.sessionID = sessionID
        self.placement = placement
        self.acknowledged = acknowledged
    }
}

/// Revisions and aspect the user accepted with "Mark as OK" (A §4.4, Phase 7). `boxAspect`
/// is cleared whenever a new version is placed in the slot.
public struct FlagBaseline: Hashable, Codable, Sendable {
    public var styleRevision: Int
    public var assetRevisions: [AssetID: Int]
    public var boxAspect: Double?

    public init(styleRevision: Int = 0, assetRevisions: [AssetID: Int] = [:], boxAspect: Double? = nil) {
        self.styleRevision = styleRevision
        self.assetRevisions = assetRevisions
        self.boxAspect = boxAspect
    }
}

public struct ImagePlacement: Hashable, Codable, Sendable {
    public var versionID: VersionID
    /// ≥ 1.0; 1.0 = aspect-fill of the box.
    public var zoom: Double
    /// Focal point in image-normalized coordinates (0…1, origin top-left).
    public var center: NormalizedPoint
    /// Box aspect (width / height) when placed; used for the "layout changed" flag.
    public var boxAspectWhenPlaced: Double

    public init(versionID: VersionID, zoom: Double = 1, center: NormalizedPoint = .center, boxAspectWhenPlaced: Double) {
        self.versionID = versionID
        self.zoom = zoom
        self.center = center
        self.boxAspectWhenPlaced = boxAspectWhenPlaced
    }
}
