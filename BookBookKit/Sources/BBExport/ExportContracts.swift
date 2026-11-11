import BBLayout
import BBModel
import CoreGraphics
import Foundation

// Phase 14 contracts (main thread). Lanes implement the stubbed bodies in their own files and
// must not change these signatures; ask the main thread instead. A §9, PD §8.8.
//
// UNITS: sizes and rects are PDF points (1/72 in) unless the name says pixels.
// PAGE NUMBERS: "reading positions" are 1-based, as numbered by `PageSequencer` (a spread
// takes two positions). The cover is never part of a range; it's controlled by `includeCover`.

// MARK: - Options

public enum SheetSize: String, CaseIterable, Hashable, Sendable, Codable {
    case letter, a4, tabloid, a3

    /// Portrait size in points: Letter 612×792, A4 595.28×841.89, Tabloid 792×1224, A3 841.89×1190.55.
    public var portraitSize: CGSize {
        switch self {
        case .letter: CGSize(width: 612, height: 792)
        case .a4: CGSize(width: 595.28, height: 841.89)
        case .tabloid: CGSize(width: 792, height: 1224)
        case .a3: CGSize(width: 841.89, height: 1190.55)
        }
    }

    public var displayName: String {
        switch self {
        case .letter: "Letter"
        case .a4: "A4"
        case .tabloid: "Tabloid"
        case .a3: "A3"
        }
    }
}

public enum ExportKind: Hashable, Sendable, Codable {
    /// Home printing: media box = trim, no bleed.
    case standard
    /// Bleed + crop marks + TrimBox/BleedBox. Requires `PageSetup.bleedEnabled`.
    case printShop
    /// Two-up fold-and-staple imposition on a sheet.
    case booklet(SheetSize)
}

public enum SpreadOutput: String, Hashable, Sendable, Codable {
    /// Each half of a spread becomes its own PDF page (default).
    case singlePages
    /// A spread becomes one double-width PDF page. Ignored for booklets.
    case doubleWidth
}

public struct ExportOptions: Hashable, Sendable, Codable {
    public var kind: ExportKind
    public var includeCover: Bool
    /// Reading positions to include (see the header); nil = all. A page is included when any
    /// of its positions falls inside the range.
    public var pageRange: ClosedRange<Int>?
    public var spreads: SpreadOutput

    public init(kind: ExportKind = .standard, includeCover: Bool = true,
                pageRange: ClosedRange<Int>? = nil, spreads: SpreadOutput = .singlePages) {
        self.kind = kind
        self.includeCover = includeCover
        self.pageRange = pageRange
        self.spreads = spreads
    }
}

public enum BitmapFormat: String, Hashable, Sendable, Codable {
    case png, jpeg
}

// MARK: - Results, progress, errors

public struct ExportProgress: Hashable, Sendable {
    public var completedUnits: Int
    public var totalUnits: Int
    public init(completedUnits: Int, totalUnits: Int) {
        self.completedUnits = completedUnits
        self.totalUnits = totalUnits
    }
    public var fraction: Double { totalUnits == 0 ? 1 : Double(completedUnits) / Double(totalUnits) }
}

public struct ExportResult: Hashable, Sendable {
    /// PDF pages written.
    public var pageCount: Int
    /// Booklet only: blank pages added to reach a multiple of 4.
    public var blanksAdded: Int
    /// Booklet only: ≤ 1, the factor pages were scaled by to fit two-up.
    public var scale: CGFloat
    /// Booklet only: e.g. "Print double-sided, flip on short edge."
    public var printingInstructions: String?
    /// Booklet only: pages were scaled down to fit two-up (`scale` < 1), as `BookletSheetLayout`.
    public var scaledToFit: Bool { BookletImposition.isScaledToFit(scale) }
    public init(pageCount: Int, blanksAdded: Int = 0, scale: CGFloat = 1, printingInstructions: String? = nil) {
        self.pageCount = pageCount
        self.blanksAdded = blanksAdded
        self.scale = scale
        self.printingInstructions = printingInstructions
    }
}

public enum ExportError: Error, Equatable, Sendable {
    case noPages
    /// Print shop asked for while `PageSetup.bleedEnabled` is false.
    case bleedRequired
    case contextCreationFailed
    case imageUnreadable(ImageRef)
    case encodingFailed
}

// MARK: - Booklet imposition (A §9.3)

/// One side of one booklet sheet. Page numbers are 1-based positions in the padded sequence.
public struct SheetSide: Hashable, Sendable {
    /// 0-based sheet index (sheet 0 is the outer sheet).
    public var sheet: Int
    public var isFront: Bool
    public var leftPage: Int
    public var rightPage: Int
    public init(sheet: Int, isFront: Bool, leftPage: Int, rightPage: Int) {
        self.sheet = sheet
        self.isFront = isFront
        self.leftPage = leftPage
        self.rightPage = rightPage
    }
}

/// Where the two page slots go on a sheet side.
public struct BookletSheetLayout: Hashable, Sendable {
    /// The sheet's media size (landscape for portrait pages laid side by side).
    public var sheetSize: CGSize
    /// Slot rects in sheet space, origin top-left, y down. `firstSlot` holds `SheetSide.leftPage`.
    public var firstSlot: CGRect
    public var secondSlot: CGRect
    /// ≤ 1. Pages are scaled by this and centred in their slot.
    public var scale: CGFloat
    public var scaledToFit: Bool { BookletImposition.isScaledToFit(scale) }
    public var printingInstructions: String
    public init(sheetSize: CGSize, firstSlot: CGRect, secondSlot: CGRect, scale: CGFloat,
                printingInstructions: String) {
        self.sheetSize = sheetSize
        self.firstSlot = firstSlot
        self.secondSlot = secondSlot
        self.scale = scale
        self.printingInstructions = printingInstructions
    }
}

public enum BookletImposition {
    /// Whether a booklet `scale` shrinks pages. `layout(pageSize:sheet:)` already snaps a scale
    /// within `tolerance` of 1 to exactly 1; the margin here only absorbs float noise.
    static func isScaledToFit(_ scale: CGFloat) -> Bool { scale < 0.9999 }

    /// `n` rounded up to a multiple of 4 (minimum 4).
    public static func paddedCount(_ n: Int) -> Int {
        max(4, (n + 3) / 4 * 4)
    }

    /// Blanks around the booklet's content so every story page keeps `PageSequencer`'s side
    /// (odd position = right-hand = odd booklet page). `leading` is 0 or 1, placed after the
    /// cover (the inside front cover) or before the first page of a range that starts on an
    /// even position; `trailing` pads the total to a multiple of 4. `contentPages` counts the
    /// cover when included; `firstStoryPosition` is nil when no story page is selected.
    public static func blanks(contentPages: Int, includeCover: Bool,
                              firstStoryPosition: Int?) -> (leading: Int, trailing: Int) {
        var leading = 0
        if let first = firstStoryPosition {
            let firstBookletPage = includeCover ? 2 : 1
            leading = (firstBookletPage - first) % 2 == 0 ? 0 : 1
        }
        let total = contentPages + leading
        return (leading, paddedCount(total) - total)
    }

    /// Sheet sides for `n` pages (n a multiple of 4), front then back for each sheet:
    /// front (n − 2s, 1 + 2s), back (2 + 2s, n − 1 − 2s), s = 0…n/4 − 1.
    public static func sheetSides(pageCount n: Int) -> [SheetSide] {
        precondition(n > 0 && n % 4 == 0, "booklet page count must be a positive multiple of 4")
        return (0..<(n / 4)).flatMap { s in
            [SheetSide(sheet: s, isFront: true, leftPage: n - 2 * s, rightPage: 1 + 2 * s),
             SheetSide(sheet: s, isFront: false, leftPage: 2 + 2 * s, rightPage: n - 1 - 2 * s)]
        }
    }
}

// MARK: - Print-shop marks (A §9.1)

public enum CropMarks {
    /// Mark area outside the bleed: 0.25 in.
    public static let markArea: CGFloat = 18
    /// Gap between the bleed edge and the start of each mark.
    public static let offsetFromBleed: CGFloat = 3
    public static let lineWidth: CGFloat = 0.25
}

public struct CropMarkSegment: Hashable, Sendable {
    public var start: CGPoint
    public var end: CGPoint
    public init(start: CGPoint, end: CGPoint) {
        self.start = start
        self.end = end
    }
}

// MARK: - Image preparation (A §9.2)

public protocol Upscaler: Sendable {
    func upscale(_ image: CGImage, to size: CGSize) async throws -> CGImage
}

public enum PrintResolution {
    public static let dpi: CGFloat = 300
    /// Tunable softness thresholds (A §9.2 step 4).
    public static let softUpscaleFactor: Double = 2.5
    public static let softShortSidePixels: Int = 600

    public static func isSoft(upscaleFactor: Double, cropShortSidePixels: Int) -> Bool {
        // The short-side rule only matters when the image is enlarged: a small crop that is
        // downsampled into a small box is fine.
        upscaleFactor > softUpscaleFactor || (upscaleFactor > 1 && cropShortSidePixels < softShortSidePixels)
    }
}

/// Everything needed to prepare one box's image, built on the main actor from a book snapshot.
public struct ImagePreparationRequest: Hashable, Sendable {
    public var key: BoxImageKey
    public var image: ImageRef
    public var sourceURL: URL
    /// Visible part of the source, in source pixels, origin top-left.
    public var cropPixels: CGRect
    /// Box render rect in inches × 300, rounded up.
    public var requiredPixels: CGSize
    public init(key: BoxImageKey, image: ImageRef, sourceURL: URL, cropPixels: CGRect, requiredPixels: CGSize) {
        self.key = key
        self.image = image
        self.sourceURL = sourceURL
        self.cropPixels = cropPixels
        self.requiredPixels = requiredPixels
    }
}

public struct ImageAssessment: Hashable, Sendable {
    public var key: BoxImageKey
    public var image: ImageRef
    public var availablePixels: CGSize
    public var requiredPixels: CGSize
    /// required / available on the limiting axis; ≤ 1 means downsampling.
    public var upscaleFactor: Double
    public var isSoft: Bool
    public init(key: BoxImageKey, image: ImageRef, availablePixels: CGSize, requiredPixels: CGSize,
                upscaleFactor: Double, isSoft: Bool) {
        self.key = key
        self.image = image
        self.availablePixels = availablePixels
        self.requiredPixels = requiredPixels
        self.upscaleFactor = upscaleFactor
        self.isSoft = isSoft
    }
}

/// What the exporter needs from image preparation; `ExportImagePreparer` conforms. Tests fake it.
public protocol ImagePreparing: Sendable {
    func assess(_ request: ImagePreparationRequest) async -> ImageAssessment
    func prepare(_ request: ImagePreparationRequest) async throws -> CGImage
}

// MARK: - Preflight (A §9.4)

public struct PreflightIssue: Hashable, Sendable, Identifiable {
    public enum Kind: String, CaseIterable, Hashable, Sendable {
        case emptyImageBox, textOverflow, spelling, softImage
        case styleChanged, assetChanged, layoutChanged, consistencyWarning
        case missingFont

        /// Group heading in the export sheet.
        public var groupTitle: String {
            switch self {
            case .emptyImageBox: "Empty image boxes"
            case .textOverflow: "Text that doesn't fit"
            case .spelling: "Spelling"
            case .softImage: "Images that will look soft"
            case .styleChanged: "Style changed"
            case .assetChanged: "Asset changed"
            case .layoutChanged: "Layout changed"
            case .consistencyWarning: "Consistency warnings"
            case .missingFont: "Missing fonts"
            }
        }
    }

    public var kind: Kind
    /// Navigation target.
    public var page: PageID
    public var box: BoxID?
    /// Short line, e.g. "“teh”", "Pip is 512 px; needs 2550 px", "Font “Fraunces” isn't installed".
    public var detail: String

    public var id: String { "\(kind.rawValue)|\(page)|\(box.map { "\($0)" } ?? "-")|\(detail)" }

    public init(kind: Kind, page: PageID, box: BoxID? = nil, detail: String) {
        self.kind = kind
        self.page = page
        self.box = box
        self.detail = detail
    }
}

/// Spelling is injected so tests don't depend on the system dictionary.
@MainActor
public protocol SpellingChecking: AnyObject {
    /// Misspelled words in `text`, in order.
    func misspelledWords(in text: String) -> [String]
}
