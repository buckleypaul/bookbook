import BBModel
import CoreGraphics
import Foundation

/// Page geometry from `PageSetup` (A §8.2). Phase 2: single pages, no bleed in practice.
///
/// All rects are in points in trim space: origin at the trim's top-left, y down. "Leading" is
/// the left edge and "trailing" the right edge (pages are laid out left-to-right).
public struct PageGeometry: Hashable, Sendable {
    /// The minimum safe-area inset when bleed is on: 0.125 in (A §8.2).
    public static let minimumSafeInsetWithBleed: CGFloat = 9

    public var setup: PageSetup

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

    /// The box's normalized frame times the trim size, with each edge in `bleedEdges` pushed
    /// out by the bleed. Top-left origin, y down.
    public func renderRect(for box: Box) -> CGRect {
        let size = trimSize
        var minX = CGFloat(box.frame.x) * size.width
        var minY = CGFloat(box.frame.y) * size.height
        var maxX = CGFloat(box.frame.maxX) * size.width
        var maxY = CGFloat(box.frame.maxY) * size.height
        let b = bleed
        if b > 0 {
            if box.bleedEdges.contains(.top) { minY -= b }
            if box.bleedEdges.contains(.leading) { minX -= b }
            if box.bleedEdges.contains(.bottom) { maxY += b }
            if box.bleedEdges.contains(.trailing) { maxX += b }
        }
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
