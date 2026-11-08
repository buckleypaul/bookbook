import AppKit
import BBModel
import Foundation

// Owned by the Layout lane. Contract stub: signatures are frozen, bodies are placeholders.

/// TextKit 2 layout of one text box (A §8.3): `NSTextContentStorage` + `NSTextLayoutManager`
/// with a fixed-size container using `TextContainerSettings`. Never touches TextKit 1.
@MainActor
public final class TextBoxLayout {
    /// `containerSize` is the box's render rect size minus its padding.
    public init(text: RichText, typography: Typography, containerSize: CGSize) {
        fatalError("Phase 2 Layout lane: not implemented")
    }

    /// True if the laid-out text is taller than the container or doesn't reach the end.
    public var isOverflowing: Bool { fatalError("Phase 2 Layout lane: not implemented") }

    /// Draws the fragments with `draw(at:in:)` into `ctx`, whose user space is top-left origin,
    /// y down, in points; `origin` is the container's top-left. Text stays real text in PDFs.
    public func draw(in ctx: CGContext, origin: CGPoint) {
        fatalError("Phase 2 Layout lane: not implemented")
    }
}
