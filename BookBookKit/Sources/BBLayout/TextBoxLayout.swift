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
    // NSTextContentStorage only weakly references its layout managers, so all three stay here.
    private let contentStorage = NSTextContentStorage()
    private let layoutManager = NSTextLayoutManager()
    private let container: NSTextContainer
    private var fragments: [NSTextLayoutFragment] = []

    /// `containerSize` is the box's render rect size minus its padding.
    public convenience init(text: RichText, typography: Typography, containerSize: CGSize) {
        self.init(attributedString: RichTextBridge.attributedString(from: text, typography: typography),
                  containerSize: containerSize)
    }

    /// Lays out an already-converted string (the editor overlay can measure with this).
    public init(attributedString: NSAttributedString, containerSize: CGSize) {
        let size = CGSize(width: max(0, containerSize.width), height: max(0, containerSize.height))
        self.containerSize = size
        container = NSTextContainer(size: size)
        container.lineFragmentPadding = TextContainerSettings.lineFragmentPadding
        layoutManager.textContainer = container
        contentStorage.addTextLayoutManager(layoutManager)
        contentStorage.textStorage = NSTextStorage(attributedString: attributedString)
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        var collected: [NSTextLayoutFragment] = []
        layoutManager.enumerateTextLayoutFragments(from: layoutManager.documentRange.location,
                                                   options: [.ensuresLayout]) { fragment in
            collected.append(fragment)
            return true
        }
        fragments = collected
    }

    /// The height the laid-out text uses.
    public var usedHeight: CGFloat { layoutManager.usageBoundsForTextContainer.height }

    /// True if the laid-out text is taller than the container or doesn't reach the end.
    public var isOverflowing: Bool {
        // No text can't overflow, even in a box too small for an empty line.
        if (contentStorage.textStorage?.length ?? 0) == 0 { return false }
        if usedHeight > containerSize.height + Self.overflowTolerance { return true }
        let documentEnd = layoutManager.documentRange.endLocation
        guard let last = fragments.last else {
            // Nothing laid out: overflowing only if there was text to lay out.
            return contentStorage.textStorage.map { $0.length > 0 } ?? false
        }
        return last.rangeInElement.endLocation.compare(documentEnd) == .orderedAscending
    }

    /// Draws the fragments with `draw(at:in:)` into `ctx`, whose user space is top-left origin,
    /// y down, in points; `origin` is the container's top-left. Text stays real text in PDFs.
    ///
    /// Lines that don't fit entirely inside the container are not drawn (overset text is hidden;
    /// the canvas badge and preflight report it).
    public func draw(in ctx: CGContext, origin: CGPoint) {
        guard !fragments.isEmpty else { return }
        let visibleBottom = lastVisibleLineBottom()
        guard visibleBottom > 0 else { return }

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

    /// The bottom (container coordinates) of the last line that fits entirely in the container.
    private func lastVisibleLineBottom() -> CGFloat {
        let limit = containerSize.height + Self.overflowTolerance
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
        return max(bottom, containerSize.height) + max(containerSize.height, 100)
    }
}
