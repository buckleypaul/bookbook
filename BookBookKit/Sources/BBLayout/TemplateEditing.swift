import BBModel
import CoreGraphics

// Phase 6 contracts: geometry for the template editor (A §8.2, PD §8.4).
// All rects here are in page points of a `PageGeometry` (top-left origin, y down), and are
// *trim* rects: the box's normalized frame times the trim size, with no bleed push-out.
// The canvas edits trim rects and converts back with `normalizedFrame(for:)`.

// MARK: - Normalized-frame conversion

extension PageGeometry {
    /// `frame` times the trim size, ignoring bleed edges (the rect the editor manipulates).
    public func trimRect(for frame: NormalizedRect) -> CGRect {
        fatalError("Phase 6 lane L2")
    }

    /// Inverse of `trimRect(for:)`. Not clamped: boxes may extend past the trim.
    public func normalizedFrame(for rect: CGRect) -> NormalizedRect {
        fatalError("Phase 6 lane L2")
    }

    /// One safe area per page: one rect for a single page or cover, two (left half, right
    /// half) for a spread geometry, each inset by the margins on all four sides of its own
    /// half (the gutter margin applies on both sides of the fold).
    public var pageSafeAreas: [CGRect] {
        fatalError("Phase 6 lane L2")
    }
}

// MARK: - Hit-testing with rotation

/// A box handle in the editor. Handles sit on the box's rotated outline.
public enum BoxHandle: Hashable, Sendable, CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    /// The rotation knob, a short distance above the top edge's midpoint.
    case rotation

    /// The edges a resize handle moves (empty for `.rotation`).
    public var movingEdges: EdgeSet { fatalError("Phase 6 lane L2") }
}

/// A box as the editor sees it: its trim rect and rotation.
public struct EditableBox: Hashable, Sendable {
    public var id: BoxID
    public var rect: CGRect
    public var rotationDegrees: Double

    public init(id: BoxID, rect: CGRect, rotationDegrees: Double) {
        self.id = id
        self.rect = rect
        self.rotationDegrees = rotationDegrees
    }
}

public enum BoxHitTesting {
    /// `point` in the box's unrotated frame: the inverse of the rotation about the rect's
    /// centre (positive degrees = clockwise on screen, as `PageRenderer` draws).
    public static func unrotate(_ point: CGPoint, rect: CGRect, rotationDegrees: Double) -> CGPoint {
        fatalError("Phase 6 lane L2")
    }

    /// The topmost box (last in layer order) containing `point`, honouring rotation.
    public static func box(at point: CGPoint, in boxes: [EditableBox]) -> BoxID? {
        fatalError("Phase 6 lane L2")
    }

    /// The handle within `tolerance` points of `point`, if any. `rotationKnobOffset` is the
    /// knob's distance above the top edge (both in page points; the canvas scales them by
    /// 1/zoom so they stay a constant size on screen).
    public static func handle(at point: CGPoint, of box: EditableBox, tolerance: CGFloat,
                              rotationKnobOffset: CGFloat) -> BoxHandle? {
        fatalError("Phase 6 lane L2")
    }

    /// Where a handle sits, in page points (rotated).
    public static func position(of handle: BoxHandle, of box: EditableBox,
                                rotationKnobOffset: CGFloat) -> CGPoint {
        fatalError("Phase 6 lane L2")
    }

    /// The axis-aligned bounds of the rotated rect.
    public static func rotatedBounds(_ box: EditableBox) -> CGRect {
        fatalError("Phase 6 lane L2")
    }
}

// MARK: - Snapping

/// A snap guide line drawn while dragging, in page points.
public struct SnapGuide: Hashable, Sendable {
    public enum Axis: Hashable, Sendable { case vertical, horizontal }
    public var axis: Axis
    /// x for a vertical guide, y for a horizontal one.
    public var position: CGFloat
    /// The extent along the guide to draw (y range for vertical, x range for horizontal).
    public var span: ClosedRange<CGFloat>

    public init(axis: Axis, position: CGFloat, span: ClosedRange<CGFloat>) {
        self.axis = axis
        self.position = position
        self.span = span
    }
}

/// Lines a moving box can snap to.
public struct SnapTargets: Hashable, Sendable {
    public var xs: [CGFloat]
    public var ys: [CGFloat]

    public init(xs: [CGFloat], ys: [CGFloat]) {
        self.xs = xs
        self.ys = ys
    }

    /// Margins (each page's safe area edges), the trim edges, each page's centre lines, the
    /// fold (spreads), and the edges and centres of `others` (their rotated bounds).
    public static func make(geometry: PageGeometry, isSpread: Bool, others: [EditableBox]) -> SnapTargets {
        fatalError("Phase 6 lane L2")
    }
}

public struct SnapResult: Hashable, Sendable {
    public var rect: CGRect
    public var guides: [SnapGuide]

    public init(rect: CGRect, guides: [SnapGuide]) {
        self.rect = rect
        self.guides = guides
    }
}

public enum Snapping {
    /// Snap a moved rect: its left/centre/right to the nearest x target and its
    /// top/centre/bottom to the nearest y target, each independently, when within
    /// `threshold`. Size is unchanged.
    public static func snapMove(_ rect: CGRect, to targets: SnapTargets, threshold: CGFloat) -> SnapResult {
        fatalError("Phase 6 lane L2")
    }

    /// Snap only the edges in `movingEdges` (a resize); other edges stay put. A snapped edge
    /// never makes the rect smaller than `minSize` on that axis.
    public static func snapResize(_ rect: CGRect, movingEdges: EdgeSet, to targets: SnapTargets,
                                  threshold: CGFloat, minSize: CGFloat) -> SnapResult {
        fatalError("Phase 6 lane L2")
    }

    /// Snap an angle to the nearest multiple of `step` degrees when within `threshold` degrees.
    public static func snapAngle(_ degrees: Double, step: Double, threshold: Double) -> Double {
        fatalError("Phase 6 lane L2")
    }
}

// MARK: - Align and distribute

public enum AlignOperation: Hashable, Sendable, CaseIterable {
    case left, horizontalCenter, right, top, verticalCenter, bottom
}

public enum DistributeAxis: Hashable, Sendable {
    case horizontal, vertical
}

public enum Arrangement {
    /// Align frames to `reference`, or to the union of the frames when nil (the canvas passes
    /// the page's safe area, normalized, when a single box is selected). Unrotated frames.
    public static func align(_ frames: [BoxID: NormalizedRect], _ operation: AlignOperation,
                             reference: NormalizedRect?) -> [BoxID: NormalizedRect] {
        fatalError("Phase 6 lane L2")
    }

    /// Equal gaps between neighbours along `axis`, keeping the first and last (by min edge)
    /// in place. Fewer than three frames: returned unchanged.
    public static func distribute(_ frames: [BoxID: NormalizedRect],
                                  axis: DistributeAxis) -> [BoxID: NormalizedRect] {
        fatalError("Phase 6 lane L2")
    }
}
