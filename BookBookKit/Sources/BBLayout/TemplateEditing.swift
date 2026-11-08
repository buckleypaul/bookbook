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
        let size = trimSize
        return CGRect(x: CGFloat(frame.x) * size.width, y: CGFloat(frame.y) * size.height,
                      width: CGFloat(frame.width) * size.width, height: CGFloat(frame.height) * size.height)
    }

    /// Inverse of `trimRect(for:)`. Not clamped: boxes may extend past the trim.
    public func normalizedFrame(for rect: CGRect) -> NormalizedRect {
        let size = trimSize
        let w = size.width > 0 ? size.width : 1
        let h = size.height > 0 ? size.height : 1
        return NormalizedRect(x: Double(rect.minX / w), y: Double(rect.minY / h),
                              width: Double(rect.width / w), height: Double(rect.height / h))
    }

    /// One safe area per page: one rect for a single page or cover, two (left half, right
    /// half) for a spread geometry, each inset by the margins on all four sides of its own
    /// half (the gutter margin applies on both sides of the fold).
    public var pageSafeAreas: [CGRect] {
        safeAreas(spread: isSpread)
    }
}

// MARK: - Hit-testing with rotation

/// A box handle in the editor. Handles sit on the box's rotated outline.
public enum BoxHandle: Hashable, Sendable, CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    /// The rotation knob, a short distance above the top edge's midpoint.
    case rotation

    /// The edges a resize handle moves (empty for `.rotation`).
    public var movingEdges: EdgeSet { switch self {
        case .topLeft: [.top, .leading]
        case .top: [.top]
        case .topRight: [.top, .trailing]
        case .right: [.trailing]
        case .bottomRight: [.bottom, .trailing]
        case .bottom: [.bottom]
        case .bottomLeft: [.bottom, .leading]
        case .left: [.leading]
        case .rotation: []
        } }
}

/// A box as the editor sees it: its trim rect and rotation.
public struct EditableBox: Hashable, Sendable {
    public var id: BoxID
    public var rect: CGRect
    public var rotationDegrees: Double
    /// Text boxes draw above all image boxes whatever their layer order (A §8), so they are hit first.
    public var isText: Bool

    public init(id: BoxID, rect: CGRect, rotationDegrees: Double, isText: Bool = false) {
        self.id = id
        self.rect = rect
        self.rotationDegrees = rotationDegrees
        self.isText = isText
    }
}

public enum BoxHitTesting {
    /// `point` in the box's unrotated frame: the inverse of the rotation about the rect's
    /// centre (positive degrees = clockwise on screen, as `PageRenderer` draws).
    public static func unrotate(_ point: CGPoint, rect: CGRect, rotationDegrees: Double) -> CGPoint {
        rotate(point, about: CGPoint(x: rect.midX, y: rect.midY), degrees: -rotationDegrees)
    }

    /// The topmost box containing `point`, honouring rotation. Follows the draw order: text boxes
    /// (last in layer order first) are hit before any image box, then image boxes in reverse layer order.
    public static func box(at point: CGPoint, in boxes: [EditableBox]) -> BoxID? {
        let topFirst = boxes.reversed().filter(\.isText) + boxes.reversed().filter { !$0.isText }
        return topFirst.first {
            $0.rect.contains(unrotate(point, rect: $0.rect, rotationDegrees: $0.rotationDegrees))
        }?.id
    }

    /// The handle within `tolerance` points of `point`, if any. `rotationKnobOffset` is the
    /// knob's distance above the top edge (both in page points; the canvas scales them by
    /// 1/zoom so they stay a constant size on screen).
    public static func handle(at point: CGPoint, of box: EditableBox, tolerance: CGFloat,
                              rotationKnobOffset: CGFloat) -> BoxHandle? {
        var best: (handle: BoxHandle, distance: CGFloat)?
        for handle in BoxHandle.allCases {
            let p = position(of: handle, of: box, rotationKnobOffset: rotationKnobOffset)
            let d = hypot(p.x - point.x, p.y - point.y)
            guard d <= tolerance else { continue }
            if best == nil || d < best!.distance { best = (handle, d) }
        }
        return best?.handle
    }

    /// Where a handle sits, in page points (rotated).
    public static func position(of handle: BoxHandle, of box: EditableBox,
                                rotationKnobOffset: CGFloat) -> CGPoint {
        let r = box.rect
        let local: CGPoint
        switch handle {
        case .topLeft: local = CGPoint(x: r.minX, y: r.minY)
        case .top: local = CGPoint(x: r.midX, y: r.minY)
        case .topRight: local = CGPoint(x: r.maxX, y: r.minY)
        case .right: local = CGPoint(x: r.maxX, y: r.midY)
        case .bottomRight: local = CGPoint(x: r.maxX, y: r.maxY)
        case .bottom: local = CGPoint(x: r.midX, y: r.maxY)
        case .bottomLeft: local = CGPoint(x: r.minX, y: r.maxY)
        case .left: local = CGPoint(x: r.minX, y: r.midY)
        case .rotation: local = CGPoint(x: r.midX, y: r.minY - rotationKnobOffset)
        }
        return rotate(local, about: CGPoint(x: r.midX, y: r.midY), degrees: box.rotationDegrees)
    }

    /// The axis-aligned bounds of the rotated rect.
    public static func rotatedBounds(_ box: EditableBox) -> CGRect {
        let r = box.rect
        guard box.rotationDegrees != 0, box.rotationDegrees.isFinite else { return r }
        let c = CGPoint(x: r.midX, y: r.midY)
        let corners = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                       CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
            .map { rotate($0, about: c, degrees: box.rotationDegrees) }
        let xs = corners.map(\.x), ys = corners.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
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
        let size = geometry.trimSize
        let pages = geometry.safeAreas(spread: isSpread)
        let pageCount = CGFloat(max(1, pages.count))
        let pageWidth = size.width / pageCount
        var xs: [CGFloat] = [0, size.width]
        var ys: [CGFloat] = [0, size.height, size.height / 2]
        for (index, safe) in pages.enumerated() {
            xs += [safe.minX, safe.maxX, pageWidth * (CGFloat(index) + 0.5)]
            ys += [safe.minY, safe.maxY]
        }
        if isSpread { xs.append(geometry.foldX) }
        for other in others {
            let b = BoxHitTesting.rotatedBounds(other)
            xs += [b.minX, b.midX, b.maxX]
            ys += [b.minY, b.midY, b.maxY]
        }
        return SnapTargets(xs: dedupedSorted(xs), ys: dedupedSorted(ys))
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
        var rect = rect
        if let dx = bestShift([rect.minX, rect.midX, rect.maxX], targets.xs, threshold) { rect.origin.x += dx }
        if let dy = bestShift([rect.minY, rect.midY, rect.maxY], targets.ys, threshold) { rect.origin.y += dy }
        var guides: [SnapGuide] = []
        let ySpan = rect.minY...max(rect.minY, rect.maxY)
        let xSpan = rect.minX...max(rect.minX, rect.maxX)
        for x in dedupedSorted([rect.minX, rect.midX, rect.maxX]) where targets.xs.contains(where: { abs($0 - x) < epsilon }) {
            guides.append(SnapGuide(axis: .vertical, position: x, span: ySpan))
        }
        for y in dedupedSorted([rect.minY, rect.midY, rect.maxY]) where targets.ys.contains(where: { abs($0 - y) < epsilon }) {
            guides.append(SnapGuide(axis: .horizontal, position: y, span: xSpan))
        }
        return SnapResult(rect: rect, guides: guides)
    }

    /// Snap only the edges in `movingEdges` (a resize); other edges stay put. A snapped edge
    /// never makes the rect smaller than `minSize` on that axis.
    public static func snapResize(_ rect: CGRect, movingEdges: EdgeSet, to targets: SnapTargets,
                                  threshold: CGFloat, minSize: CGFloat) -> SnapResult {
        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        var snappedX: [CGFloat] = [], snappedY: [CGFloat] = []
        if movingEdges.contains(.leading), let t = nearest(minX, targets.xs, threshold), t <= maxX - minSize {
            minX = t; snappedX.append(t)
        }
        if movingEdges.contains(.trailing), let t = nearest(maxX, targets.xs, threshold), t >= minX + minSize {
            maxX = t; snappedX.append(t)
        }
        if movingEdges.contains(.top), let t = nearest(minY, targets.ys, threshold), t <= maxY - minSize {
            minY = t; snappedY.append(t)
        }
        if movingEdges.contains(.bottom), let t = nearest(maxY, targets.ys, threshold), t >= minY + minSize {
            maxY = t; snappedY.append(t)
        }
        let result = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        let guides = snappedX.map { SnapGuide(axis: .vertical, position: $0, span: result.minY...max(result.minY, result.maxY)) }
            + snappedY.map { SnapGuide(axis: .horizontal, position: $0, span: result.minX...max(result.minX, result.maxX)) }
        return SnapResult(rect: result, guides: guides)
    }

    /// Snap an angle to the nearest multiple of `step` degrees when within `threshold` degrees.
    public static func snapAngle(_ degrees: Double, step: Double, threshold: Double) -> Double {
        guard step > 0, degrees.isFinite else { return degrees }
        let snapped = (degrees / step).rounded() * step
        return abs(snapped - degrees) <= threshold ? snapped : degrees
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
        guard !frames.isEmpty else { return frames }
        let ref = reference ?? union(of: Array(frames.values))
        var result = frames
        for (id, f) in frames {
            var n = f
            switch operation {
            case .left: n.x = ref.x
            case .horizontalCenter: n.x = ref.x + ref.width / 2 - f.width / 2
            case .right: n.x = ref.maxX - f.width
            case .top: n.y = ref.y
            case .verticalCenter: n.y = ref.y + ref.height / 2 - f.height / 2
            case .bottom: n.y = ref.maxY - f.height
            }
            result[id] = n
        }
        return result
    }

    /// Equal gaps between neighbours along `axis`, keeping the first and last (by min edge)
    /// in place. Fewer than three frames: returned unchanged.
    public static func distribute(_ frames: [BoxID: NormalizedRect],
                                  axis: DistributeAxis) -> [BoxID: NormalizedRect] {
        guard frames.count >= 3 else { return frames }
        func lo(_ f: NormalizedRect) -> Double { axis == .horizontal ? f.x : f.y }
        func len(_ f: NormalizedRect) -> Double { axis == .horizontal ? f.width : f.height }
        let ordered = frames.sorted { a, b in
            lo(a.value) != lo(b.value) ? lo(a.value) < lo(b.value) : "\(a.key)" < "\(b.key)"
        }
        let start = lo(ordered[0].value)
        let last = ordered[ordered.count - 1].value
        let end = lo(last) + len(last)
        let gap = (end - start - ordered.reduce(0) { $0 + len($1.value) }) / Double(ordered.count - 1)
        var result = frames
        var cursor = start
        for (id, f) in ordered.dropLast() {
            var n = f
            if axis == .horizontal { n.x = cursor } else { n.y = cursor }
            result[id] = n
            cursor += len(f) + gap
        }
        return result
    }
}

// MARK: - Helpers

private let epsilon: CGFloat = 1e-6

private func rotate(_ p: CGPoint, about c: CGPoint, degrees: Double) -> CGPoint {
    guard degrees != 0, degrees.isFinite else { return p }
    let a = CGFloat(degrees) * .pi / 180
    let cs = cos(a), sn = sin(a)
    let dx = p.x - c.x, dy = p.y - c.y
    return CGPoint(x: c.x + dx * cs - dy * sn, y: c.y + dx * sn + dy * cs)
}

private func dedupedSorted(_ values: [CGFloat]) -> [CGFloat] {
    var result: [CGFloat] = []
    for v in values.sorted() where result.last.map({ abs(v - $0) >= epsilon }) ?? true {
        result.append(v)
    }
    return result
}

/// The target nearest `value`, if within `threshold`.
private func nearest(_ value: CGFloat, _ targets: [CGFloat], _ threshold: CGFloat) -> CGFloat? {
    var best: CGFloat?
    for t in targets where abs(t - value) <= threshold {
        if best == nil || abs(t - value) < abs(best! - value) { best = t }
    }
    return best
}

/// The smallest-magnitude shift taking any of `values` onto a target within `threshold`.
private func bestShift(_ values: [CGFloat], _ targets: [CGFloat], _ threshold: CGFloat) -> CGFloat? {
    var best: CGFloat?
    for v in values {
        guard let t = nearest(v, targets, threshold) else { continue }
        let d = t - v
        if best == nil || abs(d) < abs(best!) { best = d }
    }
    return best
}

private func union(of frames: [NormalizedRect]) -> NormalizedRect {
    let x0 = frames.map(\.x).min()!, y0 = frames.map(\.y).min()!
    let x1 = frames.map(\.maxX).max()!, y1 = frames.map(\.maxY).max()!
    return NormalizedRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
}

extension PageGeometry {
    /// Safe areas for one page, or for the two halves of a spread geometry.
    func safeAreas(spread: Bool) -> [CGRect] {
        guard spread else { return [safeArea] }
        var half = setup
        half.trimSize = PointSize(width: setup.trimSize.width / 2, height: setup.trimSize.height)
        let left = PageGeometry(setup: half).safeArea
        return [left, left.offsetBy(dx: trimSize.width / 2, dy: 0)]
    }
}

extension Typography {
    /// This typography with a text box's overrides applied (A 4.2 precedence: run/paragraph
    /// override > box style > style guide). nil overrides leave the style guide's values.
    public func applying(_ style: TextBoxStyle) -> Typography {
        var copy = self
        if let size = style.fontSize { copy.bodySize = size }
        if let alignment = style.alignment { copy.alignment = alignment }
        if let color = style.color { copy.color = color }
        return copy
    }
}
