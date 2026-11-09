import AppKit
import BBModel
import CoreGraphics
import Foundation

// Phase 2 contract (main thread). Implementations live in the Layout lane's files.
//
// COORDINATES: every rect here is in points, in the page's trim space, with the origin at the
// trim's TOP-LEFT and y increasing DOWNWARD (the same as NormalizedRect). PageRenderer draws
// into a context whose user space is already set up that way (see `PageRenderer.draw`).
//
// ISOLATION: TextKit 2 layout and drawing are @MainActor in Phase 2 (simple and sound; export of
// a slice-sized book on the main actor is acceptable). Phase 14 keeps rendering on the main
// actor, one page per step with a suspension in between, and moves image preparation (decode,
// crop, upscale, encode) off it (A §9.1).

/// Where a renderer gets bitmaps from.
@MainActor
public protocol PageImageSource: AnyObject {
    /// The decoded image for a ref, or nil if it can't be loaded (the box draws a placeholder).
    func image(for ref: ImageRef) -> CGImage?
}

/// Identifies one image box on one page (Phase 14): the unit `ExportImagePreparer` prepares.
public struct BoxImageKey: Hashable, Sendable, Codable {
    public var page: PageID
    public var box: BoxID
    public init(page: PageID, box: BoxID) {
        self.page = page
        self.box = box
    }
}

/// Export-time bitmaps already cropped and resampled for one box (Phase 14, A §8.4 / §9.2).
/// When a renderer has one and it returns an image for a box, the renderer draws that image
/// filling the box's `PageGeometry.renderRect(for:)` (clipped to the box shape) instead of
/// drawing the source image with its placement transform, so it never resamples itself.
@MainActor
public protocol PreparedImageSource: AnyObject {
    func preparedImage(for key: BoxImageKey) -> CGImage?
}

public struct RenderOptions: Hashable, Sendable {
    public enum Target: Hashable, Sendable {
        case screen
        case thumbnail
        /// PDF at trim size.
        case pdfTrim
        /// PDF that also draws the bleed area (print-shop output, Phase 14). The context is
        /// still in trim space (origin at the trim's top-left); content past the trim is kept.
        case pdfBleed
        /// The print path (Phase 14): same drawing as `.pdfTrim`, never any screen overlays.
        case print
    }

    public var target: Target
    /// Trim/safe-area/box outline guides (screen only).
    public var showGuides: Bool
    /// Text boxes not to draw (the one being edited in the NSTextView overlay).
    public var hiddenTextBoxes: Set<BoxID>
    /// Draw a light placeholder in empty image boxes (screen only).
    public var showEmptyImagePlaceholders: Bool
    /// Page numbers to draw (Phase 5), from `PageNumbering.marks`. Drawn last, in the
    /// template's `.pageNumberSlot` box if it has one, else at `PageNumberStyle.position`.
    public var pageNumbers: [PageNumberMark]

    /// Template-editor preview (Phase 6): sample text in text boxes without text and
    /// placeholder art in image boxes without a placement.
    public var previewSampleContent: Bool

    public init(target: Target, showGuides: Bool = false, hiddenTextBoxes: Set<BoxID> = [],
                showEmptyImagePlaceholders: Bool = false, pageNumbers: [PageNumberMark] = [],
                previewSampleContent: Bool = false) {
        self.previewSampleContent = previewSampleContent
        self.target = target
        self.showGuides = showGuides
        self.hiddenTextBoxes = hiddenTextBoxes
        self.showEmptyImagePlaceholders = showEmptyImagePlaceholders
        self.pageNumbers = pageNumbers
    }

    public static let screen = RenderOptions(target: .screen, showGuides: true, showEmptyImagePlaceholders: true)
    public static let pdf = RenderOptions(target: .pdfTrim)
}

/// Shared settings for the inline editor `NSTextView` and `TextBoxLayout` so both wrap
/// identically (A §8.3, SL-1). The editor must apply exactly these.
public enum TextContainerSettings {
    public static let lineFragmentPadding: CGFloat = 0
    public static let textContainerInset: NSSize = .zero
}

/// One page number to draw on a page (Phase 5).
public struct PageNumberMark: Hashable, Sendable {
    public var text: String
    /// 0 for a single page or a spread's left half, 1 for a spread's right half.
    public var half: Int
    /// The physical side, which decides "outer"/"inner".
    public var isLeftHand: Bool
    public init(text: String, half: Int, isLeftHand: Bool) {
        self.text = text
        self.half = half
        self.isLeftHand = isLeftHand
    }
}
