import BBLayout
import BBModel
import CoreGraphics
import Foundation

/// Pan/zoom crop maths for an image placement (A §7.5, Phase 8). Pure; every function works
/// through `PageGeometry.imageRect`, the rect `PageRenderer` draws (and export uses), so what
/// the canvas shows during a drag is what the PDF gets.
///
/// Rects are in the box's own unrotated frame (page points, y down). A rotated box's points
/// are mapped into that frame with `unrotated(_:about:degrees:)` first.
enum CropMath {
    /// The largest zoom a crop accepts.
    static let maximumZoom: Double = 8

    /// `zoom` clamped to 1…`maximumZoom` (non-finite counts as 1).
    static func clampedZoom(_ zoom: Double) -> Double {
        guard zoom.isFinite else { return 1 }
        return min(max(zoom, 1), maximumZoom)
    }

    /// The crop with `zoom` clamped and `center` replaced by the focal point the image is
    /// actually drawn with: `PageGeometry.imageRect` shifts the image so it covers the box,
    /// and the stored centre becomes the box centre's position in that rect. Drawing the
    /// result gives the same rect as drawing the input.
    static func clamped(zoom: Double, center: NormalizedPoint, imageSize: CGSize,
                        boxRect: CGRect) -> (zoom: Double, center: NormalizedPoint) {
        let zoom = clampedZoom(zoom)
        guard imageSize.width > 0, imageSize.height > 0, boxRect.width > 0, boxRect.height > 0 else {
            return (zoom, clampedUnit(center))
        }
        let probe = ImagePlacement(versionID: VersionID(), zoom: zoom, center: center, boxAspectWhenPlaced: 1)
        let rect = PageGeometry.imageRect(imageSize: imageSize, boxRect: boxRect, placement: probe)
        return (zoom, focalPoint(of: rect, boxRect: boxRect))
    }

    /// The crop after dragging the image by `delta` (page points in the box frame) from
    /// `placement`: the image follows the pointer, clamped so it still covers the box.
    static func panned(_ placement: ImagePlacement, by delta: CGSize, imageSize: CGSize,
                       boxRect: CGRect) -> (zoom: Double, center: NormalizedPoint) {
        let rect = PageGeometry.imageRect(imageSize: imageSize, boxRect: boxRect, placement: placement)
        guard rect.width > 0, rect.height > 0 else { return (clampedZoom(placement.zoom), placement.center) }
        let moved = rect.offsetBy(dx: delta.width, dy: delta.height)
        return clamped(zoom: placement.zoom, center: focalPoint(of: moved, boxRect: boxRect),
                       imageSize: imageSize, boxRect: boxRect)
    }

    /// The crop after zooming `placement` by `factor` around `anchor` (page points in the box
    /// frame): the image point under the anchor stays under it, as far as the clamps allow.
    static func zoomed(_ placement: ImagePlacement, by factor: Double, around anchor: CGPoint, imageSize: CGSize,
                       boxRect: CGRect) -> (zoom: Double, center: NormalizedPoint) {
        let oldZoom = clampedZoom(placement.zoom)
        let newZoom = clampedZoom(oldZoom * (factor.isFinite && factor > 0 ? factor : 1))
        let rect = PageGeometry.imageRect(imageSize: imageSize, boxRect: boxRect, placement: placement)
        guard rect.width > 0, rect.height > 0 else { return (newZoom, placement.center) }
        let u = (anchor.x - rect.minX) / rect.width
        let v = (anchor.y - rect.minY) / rect.height
        let scale = CGFloat(newZoom / oldZoom)
        let width = rect.width * scale, height = rect.height * scale
        let scaled = CGRect(x: anchor.x - u * width, y: anchor.y - v * height, width: width, height: height)
        return clamped(zoom: newZoom, center: focalPoint(of: scaled, boxRect: boxRect),
                       imageSize: imageSize, boxRect: boxRect)
    }

    /// `point` mapped into the unrotated frame of a box drawn rotated by `degrees` about
    /// `rect`'s centre (the inverse of `CanvasView.applyRotation`).
    static func unrotated(_ point: CGPoint, about rect: CGRect, degrees: Double) -> CGPoint {
        guard degrees != 0, degrees.isFinite else { return point }
        let delta = unrotated(CGSize(width: point.x - rect.midX, height: point.y - rect.midY), degrees: degrees)
        return CGPoint(x: rect.midX + delta.width, y: rect.midY + delta.height)
    }

    /// A page-space vector expressed in the frame of a box rotated by `degrees`.
    static func unrotated(_ vector: CGSize, degrees: Double) -> CGSize {
        guard degrees != 0, degrees.isFinite else { return vector }
        let angle = -CGFloat(degrees) * .pi / 180
        return CGSize(width: vector.width * cos(angle) - vector.height * sin(angle),
                      height: vector.width * sin(angle) + vector.height * cos(angle))
    }

    /// True when two crops are the same within rounding.
    static func isSame(_ a: (zoom: Double, center: NormalizedPoint), _ b: (zoom: Double, center: NormalizedPoint)) -> Bool {
        let tolerance = 1e-9
        return abs(a.zoom - b.zoom) <= tolerance && abs(a.center.x - b.center.x) <= tolerance
            && abs(a.center.y - b.center.y) <= tolerance
    }

    /// The box centre's position in `imageRect`, image-normalized (the focal point).
    private static func focalPoint(of imageRect: CGRect, boxRect: CGRect) -> NormalizedPoint {
        clampedUnit(NormalizedPoint(x: Double((boxRect.midX - imageRect.minX) / imageRect.width),
                                    y: Double((boxRect.midY - imageRect.minY) / imageRect.height)))
    }

    private static func clampedUnit(_ point: NormalizedPoint) -> NormalizedPoint {
        func unit(_ value: Double) -> Double { value.isFinite ? min(max(value, 0), 1) : 0.5 }
        return NormalizedPoint(x: unit(point.x), y: unit(point.y))
    }
}
