import BBModel
import CoreGraphics
import Foundation

// Owned by the Layout lane. Contract stub: signatures are frozen, bodies are placeholders.

/// Page geometry from `PageSetup` (A §8.2). Phase 2: single pages, no bleed in practice.
public struct PageGeometry: Hashable, Sendable {
    public var setup: PageSetup

    public init(setup: PageSetup) {
        self.setup = setup
    }

    /// Trim size in points.
    public var trimSize: CGSize { fatalError("Phase 2 Layout lane: not implemented") }
    /// 0 when bleed is off.
    public var bleed: CGFloat { fatalError("Phase 2 Layout lane: not implemented") }
    /// Trim inset by the margins (and by at least 0.125 in when bleed is on).
    public var safeArea: CGRect { fatalError("Phase 2 Layout lane: not implemented") }

    /// The box's normalized frame times the trim size, with each edge in `bleedEdges` pushed
    /// out by the bleed. Top-left origin, y down.
    public func renderRect(for box: Box) -> CGRect {
        fatalError("Phase 2 Layout lane: not implemented")
    }

    /// The rect the image is drawn into for an aspect-fill placement (`zoom` ≥ 1, focal point
    /// `center`), re-clamped so the image always covers `boxRect` (A §7.5).
    public static func imageRect(imageSize: CGSize, boxRect: CGRect, placement: ImagePlacement) -> CGRect {
        fatalError("Phase 2 Layout lane: not implemented")
    }
}
