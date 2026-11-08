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
// a slice-sized book on the main actor is acceptable). Phase 14 revisits for background export.

/// Where a renderer gets bitmaps from.
@MainActor
public protocol PageImageSource: AnyObject {
    /// The decoded image for a ref, or nil if it can't be loaded (the box draws a placeholder).
    func image(for ref: ImageRef) -> CGImage?
}

public struct RenderOptions: Hashable, Sendable {
    public enum Target: Hashable, Sendable {
        case screen
        case thumbnail
        /// PDF at trim size (Phase 14 adds `.pdfBleed` and `.print`).
        case pdfTrim
    }

    public var target: Target
    /// Trim/safe-area/box outline guides (screen only).
    public var showGuides: Bool
    /// Text boxes not to draw (the one being edited in the NSTextView overlay).
    public var hiddenTextBoxes: Set<BoxID>
    /// Draw a light placeholder in empty image boxes (screen only).
    public var showEmptyImagePlaceholders: Bool

    public init(target: Target, showGuides: Bool = false, hiddenTextBoxes: Set<BoxID> = [],
                showEmptyImagePlaceholders: Bool = false) {
        self.target = target
        self.showGuides = showGuides
        self.hiddenTextBoxes = hiddenTextBoxes
        self.showEmptyImagePlaceholders = showEmptyImagePlaceholders
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
