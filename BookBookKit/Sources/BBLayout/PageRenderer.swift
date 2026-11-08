import BBModel
import CoreGraphics
import Foundation

// Owned by the Layout lane. Contract stub: signatures are frozen, bodies are placeholders.

/// One renderer for screen, thumbnails and PDF (A §8.4, D8). Draw order: background, image
/// boxes in layer order (clipped, placement transform), text boxes (panel then text),
/// page number (Phase 5), screen-only guides.
@MainActor
public struct PageRenderer {
    public var images: any PageImageSource

    public init(images: any PageImageSource) {
        self.images = images
    }

    /// Draws `page` into `ctx`. The caller sets up `ctx` so its user space is the page's trim in
    /// points, origin top-left, y down (e.g. a flipped NSView, or a PDF context after
    /// `translateBy(0, h); scaleBy(1, -1)`). Missing templates or images draw nothing / a placeholder.
    public func draw(page: Page, in content: BookContent, into ctx: CGContext, options: RenderOptions) {
        fatalError("Phase 2 Layout lane: not implemented")
    }

    /// True if any text box on the page overflows.
    public func overflowingTextBoxes(page: Page, in content: BookContent) -> Set<BoxID> {
        fatalError("Phase 2 Layout lane: not implemented")
    }
}
