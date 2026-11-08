import BBModel
import CoreGraphics
import Foundation

/// Page geometry from `PageSetup` (A §8.2): trim, bleed, safe areas, render rects and the fold.
///
/// All rects are in points in trim space: origin at the trim's top-left, y down. "Leading" is
/// the left edge and "trailing" the right edge (pages are laid out left-to-right).
public struct PageGeometry: Hashable, Sendable {
    /// The minimum safe-area inset when bleed is on: 0.125 in (A §8.2).
    public static let minimumSafeInsetWithBleed: CGFloat = 9

    public var setup: PageSetup
    /// True for a spread geometry (made by `init(setup:kind: .spread)`): `setup.trimSize` is the
    /// double-width spread and the fold is at `foldX`.
    public private(set) var isSpread: Bool = false

    public init(setup: PageSetup) {
        self.setup = setup
    }

    /// Trim size in points.
    public var trimSize: CGSize {
        CGSize(width: setup.trimSize.width, height: setup.trimSize.height)
    }

    /// The trim as a rect at the origin.
    public var trimRect: CGRect { CGRect(origin: .zero, size: trimSize) }

    /// 0 when bleed is off.
    public var bleed: CGFloat {
        setup.bleedEnabled ? CGFloat(max(0, setup.bleedAmount)) : 0
    }

    /// Trim inset by the margins (and by at least 0.125 in when bleed is on).
    public var safeArea: CGRect {
        let floor: CGFloat = setup.bleedEnabled ? Self.minimumSafeInsetWithBleed : 0
        let m = setup.margins
        let top = max(CGFloat(m.top), floor)
        let left = max(CGFloat(m.leading), floor)
        let bottom = max(CGFloat(m.bottom), floor)
        let right = max(CGFloat(m.trailing), floor)
        let size = trimSize
        return CGRect(x: left, y: top,
                      width: max(0, size.width - left - right),
                      height: max(0, size.height - top - bottom))
    }

    /// The trim grown by the bleed on every side (the trim itself when bleed is off): the
    /// sheet the canvas shows and the area a bleed PDF covers.
    public var bleedRect: CGRect { trimRect.insetBy(dx: -bleed, dy: -bleed) }

    /// The edges of `box` that `renderRect(for:)` pushes out: its `bleedEdges` while bleed is
    /// on, except, on a spread, an edge lying on the fold (the fold is not a trim edge, so a
    /// half-spread full-bleed box must not spill onto the facing page).
    public func pushedBleedEdges(for box: Box) -> EdgeSet {
        guard bleed > 0, !box.bleedEdges.isEmpty else { return [] }
        var edges = box.bleedEdges
        if isSpread {
            let fold = foldX
            let tolerance: CGFloat = 0.5
            if abs(CGFloat(box.frame.x) * trimSize.width - fold) <= tolerance { edges.remove(.leading) }
            if abs(CGFloat(box.frame.maxX) * trimSize.width - fold) <= tolerance { edges.remove(.trailing) }
        }
        return edges
    }

    /// The box's normalized frame times the trim size, with each edge in `bleedEdges` pushed
    /// out by the bleed (not at a spread's fold, see `pushedBleedEdges(for:)`). Top-left origin,
    /// y down. Rotation (A §8.2) is about THIS rect's centre everywhere: `PageRenderer`, the
    /// page canvas and the template editor all rotate, outline and hit-test about the render
    /// rect's centre, so with bleed on a rotated full-bleed box pivots about the bleed-extended
    /// rect's centre (and with bleed off, about the trim frame's centre).
    public func renderRect(for box: Box) -> CGRect {
        let size = trimSize
        let trim = CGRect(x: CGFloat(box.frame.x) * size.width, y: CGFloat(box.frame.y) * size.height,
                          width: CGFloat(box.frame.width) * size.width, height: CGFloat(box.frame.height) * size.height)
        return Self.expand(trim, edges: pushedBleedEdges(for: box), by: bleed)
    }

    /// Inverse of the bleed expansion: the trim rect whose render rect is `rect`, given the
    /// edges that were pushed out (`pushedBleedEdges(for:)` of the box before the edit).
    public func trimRect(fromRender rect: CGRect, pushedEdges: EdgeSet) -> CGRect {
        Self.expand(rect, edges: pushedEdges, by: -bleed)
    }

    private static func expand(_ rect: CGRect, edges: EdgeSet, by amount: CGFloat) -> CGRect {
        guard amount != 0, !edges.isEmpty else { return rect }
        var minX = rect.minX, minY = rect.minY, maxX = rect.maxX, maxY = rect.maxY
        if edges.contains(.top) { minY -= amount }
        if edges.contains(.leading) { minX -= amount }
        if edges.contains(.bottom) { maxY += amount }
        if edges.contains(.trailing) { maxX += amount }
        return CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
    }

    /// The rect the image is drawn into for an aspect-fill placement (`zoom` ≥ 1, focal point
    /// `center`), re-clamped so the image always covers `boxRect` (A §7.5).
    ///
    /// The image is scaled to aspect-fill the box, times `zoom` (values below 1 count as 1).
    /// The focal point (image-normalized, top-left origin) goes at the box centre, then the
    /// rect is shifted as little as needed so no part of the box is left uncovered.
    public static func imageRect(imageSize: CGSize, boxRect: CGRect, placement: ImagePlacement) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, boxRect.width > 0, boxRect.height > 0 else {
            return boxRect
        }
        let zoom = CGFloat(placement.zoom.isFinite ? max(1, placement.zoom) : 1)
        let scale = max(boxRect.width / imageSize.width, boxRect.height / imageSize.height) * zoom
        let width = imageSize.width * scale
        let height = imageSize.height * scale
        let cx = CGFloat(placement.center.x.isFinite ? min(max(placement.center.x, 0), 1) : 0.5)
        let cy = CGFloat(placement.center.y.isFinite ? min(max(placement.center.y, 0), 1) : 0.5)
        var x = boxRect.midX - cx * width
        var y = boxRect.midY - cy * height
        // Keep the box covered: minX ≤ box.minX and maxX ≥ box.maxX (same for y).
        x = min(max(x, boxRect.maxX - width), boxRect.minX)
        y = min(max(y, boxRect.maxY - height), boxRect.minY)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

// MARK: Spreads

extension PageGeometry {
    /// The geometry a page is drawn and hit-tested with: the book's trim for a single page or
    /// the cover, double width for a spread (its boxes are normalized over both halves, A §4.1),
    /// with the fold at `foldX`.
    public init(setup: PageSetup, kind: TemplateKind?) {
        var setup = setup
        if kind == .spread {
            setup.trimSize = PointSize(width: setup.trimSize.width * 2, height: setup.trimSize.height)
        }
        self.init(setup: setup)
        isSpread = kind == .spread
    }

    /// A geometry for a setup that is already the draw trim (double width for a spread, as
    /// `drawContent(for:in:)` makes it): `PageRenderer` and the canvas use this so a spread's
    /// fold and per-page safe areas are known.
    public init(drawSetup: PageSetup, isSpread: Bool) {
        self.init(setup: drawSetup)
        self.isSpread = isSpread
    }

    /// The draw geometry of `page` in `drawContent` (the result of `drawContent(for:in:)`).
    public static func drawGeometry(for page: Page, in drawContent: BookContent) -> PageGeometry {
        PageGeometry(drawSetup: drawContent.style.pageSetup, isSpread: drawContent.template(for: page)?.kind == .spread)
    }

    /// The fold of a spread geometry: the middle of the trim.
    public var foldX: CGFloat { trimSize.width / 2 }

    /// `content` with its page setup replaced by `page`'s draw setup, for `PageRenderer`, which
    /// draws in `content.style.pageSetup`'s trim.
    public static func drawContent(for page: Page, in content: BookContent) -> BookContent {
        guard content.template(for: page)?.kind == .spread else { return content }
        var copy = content
        copy.style.pageSetup = PageGeometry(setup: content.style.pageSetup, kind: .spread).setup
        return copy
    }
}
