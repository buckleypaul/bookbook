import AppKit
import BBModel
import Foundation

/// TextKit 2 layout of one text box (A §8.3): `NSTextContentStorage` + `NSTextLayoutManager`
/// with a fixed-size container using `TextContainerSettings`. Never touches TextKit 1.
@MainActor
public final class TextBoxLayout {
    /// Overflow tolerance in points, so rounding in line heights doesn't flag a box that fits.
    static let overflowTolerance: CGFloat = 0.5

    public let containerSize: CGSize
    /// The height the laid-out text uses.
    public let usedHeight: CGFloat
    /// True if the laid-out text is taller than the container or doesn't reach the end.
    public let isOverflowing: Bool
    // NSTextContentStorage only weakly references its layout managers, so all three stay here.
    private let contentStorage: NSTextContentStorage
    private let layoutManager: NSTextLayoutManager
    private let container: NSTextContainer
    private let fragments: [NSTextLayoutFragment]
    /// The bottom (container coordinates) of the last line that fits entirely in the container.
    private let visibleBottom: CGFloat

    /// `containerSize` is the box's render rect size minus its padding.
    public convenience init(text: RichText, typography: Typography, containerSize: CGSize) {
        self.init(attributedString: RichTextBridge.attributedString(from: text, typography: typography),
                  containerSize: containerSize)
    }

    /// Lays out an already-converted string (the editor overlay can measure with this). The
    /// layout never changes afterwards, so its results are worked out once here.
    public init(attributedString: NSAttributedString, containerSize: CGSize) {
        let size = CGSize(width: max(0, containerSize.width), height: max(0, containerSize.height))
        let container = NSTextContainer(size: size)
        container.lineFragmentPadding = TextContainerSettings.lineFragmentPadding
        let layoutManager = NSTextLayoutManager()
        layoutManager.textContainer = container
        let contentStorage = NSTextContentStorage()
        contentStorage.addTextLayoutManager(layoutManager)
        contentStorage.textStorage = NSTextStorage(attributedString: attributedString)
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        var fragments: [NSTextLayoutFragment] = []
        layoutManager.enumerateTextLayoutFragments(from: layoutManager.documentRange.location,
                                                   options: [.ensuresLayout]) { fragment in
            fragments.append(fragment)
            return true
        }
        let usedHeight = layoutManager.usageBoundsForTextContainer.height
        let length = contentStorage.textStorage?.length ?? 0

        self.containerSize = size
        self.container = container
        self.layoutManager = layoutManager
        self.contentStorage = contentStorage
        self.fragments = fragments
        self.usedHeight = usedHeight
        if length == 0 {
            // No text can't overflow, even in a box too small for an empty line.
            isOverflowing = false
        } else if usedHeight > size.height + Self.overflowTolerance {
            isOverflowing = true
        } else if let last = fragments.last {
            isOverflowing = last.rangeInElement.endLocation
                .compare(layoutManager.documentRange.endLocation) == .orderedAscending
        } else {
            // Nothing laid out, though there was text to lay out.
            isOverflowing = true
        }
        visibleBottom = Self.lastVisibleLineBottom(of: fragments, containerHeight: size.height)
    }

    /// Draws the fragments with `draw(at:in:)` into `ctx`, whose user space is top-left origin,
    /// y down, in points; `origin` is the container's top-left. Text stays real text in PDFs.
    ///
    /// Lines that don't fit entirely inside the container are not drawn (overset text is hidden;
    /// the canvas badge and preflight report it).
    public func draw(in ctx: CGContext, origin: CGPoint) {
        guard !fragments.isEmpty, visibleBottom > 0 else { return }

        ctx.saveGState()
        defer { ctx.restoreGState() }
        // Clip vertically to whole lines; generous horizontal slack for glyph overhang.
        let slack = max(containerSize.width, 100)
        ctx.clip(to: CGRect(x: origin.x - slack, y: origin.y,
                            width: containerSize.width + 2 * slack, height: visibleBottom))

        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        defer { NSGraphicsContext.current = previous }
        for fragment in fragments {
            let frame = fragment.layoutFragmentFrame
            guard frame.minY < visibleBottom else { break }
            fragment.draw(at: CGPoint(x: origin.x + frame.minX, y: origin.y + frame.minY), in: ctx)
        }
    }

    /// The bottom (container coordinates) of the last line that fits entirely in a container
    /// `containerHeight` tall.
    private static func lastVisibleLineBottom(of fragments: [NSTextLayoutFragment],
                                              containerHeight: CGFloat) -> CGFloat {
        let limit = containerHeight + overflowTolerance
        var bottom: CGFloat = 0
        for fragment in fragments {
            let frame = fragment.layoutFragmentFrame
            for line in fragment.textLineFragments {
                let lineBottom = frame.minY + line.typographicBounds.maxY
                guard lineBottom <= limit else { return bottom }
                bottom = max(bottom, lineBottom)
            }
        }
        // Everything fits: don't clip glyph descenders that hang below the last line box.
        return max(bottom, containerHeight) + max(containerHeight, 100)
    }
}
