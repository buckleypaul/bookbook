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
    case portrait, landscape
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

    public init(trimSize: PointSize, orientation: Orientation, margins: EdgeInsetsPt,
                bleedEnabled: Bool = false, bleedAmount: Double = 9) {
        self.trimSize = trimSize
        self.orientation = orientation
        self.margins = margins
        self.bleedEnabled = bleedEnabled
        self.bleedAmount = bleedAmount
    }

    public static let letterPortrait = PageSetup(
        trimSize: PointSize(width: 612, height: 792), orientation: .portrait,
        margins: EdgeInsetsPt(all: 36))
}

/// Page number style. Minimal in Phase 2 (off); Phase 5 adds position, font, start and skips.
public struct PageNumberStyle: Hashable, Codable, Sendable {
    public var enabled: Bool
    public init(enabled: Bool = false) { self.enabled = enabled }
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

    public init(id: TemplateID = TemplateID(), name: String, kind: TemplateKind, boxes: [Box]) {
        self.id = id
        self.name = name
        self.kind = kind
        self.boxes = boxes
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

    public init(padding: Double = 0, background: RGBA? = nil) {
        self.padding = padding
        self.background = background
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

/// Revisions and aspect the user accepted with "Mark as OK" (A §4.4). Unused until Phase 7.
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
