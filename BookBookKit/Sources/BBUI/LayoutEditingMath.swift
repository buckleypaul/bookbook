import BBLayout
import BBModel
import CoreGraphics
import Foundation

/// The template editor's drag maths, kept pure for tests (`LayoutEditingController` applies
/// the results through `TemplateEditorModel`). Rects are trim rects in page points (top-left
/// origin, y down); positive degrees are clockwise on screen, as `PageRenderer` draws.
enum LayoutEditingMath {
    /// The smallest a box can be resized to, in page points.
    static let minBoxSize: CGFloat = 8
    /// Rotation always snaps to a right angle within this many degrees.
    static let rightAngleSnap: Double = 2
    /// ⇧ while rotating: snap to multiples of this.
    static let shiftRotationStep: Double = 15

    // MARK: Boxes on screen

    /// The template's boxes as the editor handles them: RENDER rects (bleed-extended when
    /// bleed is on), so outlines, handles, hit-testing and the rotation pivot match what
    /// `PageRenderer` draws (it rotates about the render rect's centre).
    static func editableBoxes(_ template: Template, geometry: PageGeometry) -> [EditableBox] {
        template.boxes.map {
            EditableBox(id: $0.id, rect: geometry.renderRect(for: $0), rotationDegrees: $0.rotationDegrees,
                        isText: $0.content != .image)
        }
    }

    /// The stored frame for a box whose render rect an edit moved to `rect`: the bleed that
    /// was pushed out (`pushedEdges`, taken before the edit) is removed, then normalized.
    static func frame(forRender rect: CGRect, pushedEdges: EdgeSet, geometry: PageGeometry) -> NormalizedRect {
        geometry.normalizedFrame(for: geometry.trimRect(fromRender: rect, pushedEdges: pushedEdges))
    }

    /// Snap targets for a drag: `SnapTargets.make`, plus the bleed's outer edges when bleed
    /// is on (a full-bleed box's render edges sit there).
    static func snapTargets(geometry: PageGeometry, others: [EditableBox]) -> SnapTargets {
        var targets = SnapTargets.make(geometry: geometry, isSpread: geometry.isSpread, others: others)
        let bleed = geometry.bleed
        guard bleed > 0 else { return targets }
        let sheet = geometry.bleedRect
        targets.xs = Array(Set(targets.xs + [sheet.minX, sheet.maxX])).sorted()
        targets.ys = Array(Set(targets.ys + [sheet.minY, sheet.maxY])).sorted()
        return targets
    }

    // MARK: Clicks

    /// The selection after a click on `hit` (nil = empty space), and whether the click may
    /// start a move. ⇧ toggles the box (and moves only if it's now selected); a plain click on
    /// an unselected box selects just it, on a selected box keeps the selection (to move it).
    static func click(on hit: BoxID?, selection: Set<BoxID>, shift: Bool) -> (selection: Set<BoxID>, canMove: Bool) {
        guard let hit else { return (shift ? selection : [], false) }
        if shift {
            var toggled = selection
            if toggled.remove(hit) == nil { toggled.insert(hit) }
            return (toggled, toggled.contains(hit))
        }
        return (selection.contains(hit) ? selection : [hit], true)
    }

    // MARK: Move

    struct MoveResult: Equatable {
        var rects: [BoxID: CGRect]
        var guides: [SnapGuide]
    }

    /// Moves `boxes` by `delta`. With `targets`, the group's rotated bounds snap (edges and
    /// centres, `Snapping.snapMove`) within `threshold`, and every box takes the same shift.
    static func move(_ boxes: [EditableBox], by delta: CGVector, targets: SnapTargets?,
                     threshold: CGFloat) -> MoveResult {
        guard !boxes.isEmpty else { return MoveResult(rects: [:], guides: []) }
        var shift = delta
        var guides: [SnapGuide] = []
        if let targets {
            let bounds = boxes.map(BoxHitTesting.rotatedBounds).reduce(CGRect.null) { $0.union($1) }
            let moved = bounds.offsetBy(dx: delta.dx, dy: delta.dy)
            let snapped = Snapping.snapMove(moved, to: targets, threshold: threshold)
            shift.dx += snapped.rect.minX - moved.minX
            shift.dy += snapped.rect.minY - moved.minY
            guides = snapped.guides
        }
        var rects: [BoxID: CGRect] = [:]
        for box in boxes { rects[box.id] = box.rect.offsetBy(dx: shift.dx, dy: shift.dy) }
        return MoveResult(rects: rects, guides: guides)
    }

    // MARK: Resize

    struct ResizeResult: Equatable {
        var rect: CGRect
        var guides: [SnapGuide]
    }

    /// Resizes `box` by dragging `handle` from `start` to `current` (page points). The drag
    /// moves the handle's edges in the box's own (unrotated) frame and the opposite edges stay
    /// where they are on the page. `keepAspect` (⇧ on a corner) keeps the width:height ratio.
    /// Snapping (`targets`) applies only to an unrotated box without the aspect lock. Neither
    /// side goes below `minSize`.
    static func resize(_ box: EditableBox, handle: BoxHandle, from start: CGPoint, to current: CGPoint,
                       keepAspect: Bool, targets: SnapTargets?, threshold: CGFloat,
                       minSize: CGFloat = minBoxSize) -> ResizeResult {
        let edges = handle.movingEdges
        guard !edges.isEmpty else { return ResizeResult(rect: box.rect, guides: []) }
        let rotation = box.rotationDegrees.isFinite ? box.rotationDegrees : 0
        let d = rotateVector(CGVector(dx: current.x - start.x, dy: current.y - start.y), degrees: -rotation)
        let r = box.rect
        var minX = r.minX, maxX = r.maxX, minY = r.minY, maxY = r.maxY
        if edges.contains(.leading) { minX = min(minX + d.dx, maxX - minSize) }
        if edges.contains(.trailing) { maxX = max(maxX + d.dx, minX + minSize) }
        if edges.contains(.top) { minY = min(minY + d.dy, maxY - minSize) }
        if edges.contains(.bottom) { maxY = max(maxY + d.dy, minY + minSize) }

        let isCorner = (edges.contains(.leading) || edges.contains(.trailing))
            && (edges.contains(.top) || edges.contains(.bottom))
        let lockAspect = keepAspect && isCorner && r.width > 0 && r.height > 0
        if lockAspect {
            var width = maxX - minX, height = maxY - minY
            let aspect = r.width / r.height
            if width / r.width >= height / r.height { height = width / aspect } else { width = height * aspect }
            let grow = max(1, minSize / width, minSize / height)
            width *= grow
            height *= grow
            if edges.contains(.leading) { minX = maxX - width } else { maxX = minX + width }
            if edges.contains(.top) { minY = maxY - height } else { maxY = minY + height }
        }
        var local = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)

        var guides: [SnapGuide] = []
        if let targets, !lockAspect, isUnrotated(rotation) {
            let snapped = Snapping.snapResize(local, movingEdges: edges, to: targets, threshold: threshold,
                                              minSize: minSize)
            local = snapped.rect
            guides = snapped.guides
        }

        // The local rect was edited in the old box's frame (rotation about the old centre). The
        // stored rect rotates about its own centre, so move that centre to where the old
        // transform puts it: the fixed edges then stay put on the page.
        if !isUnrotated(rotation) {
            let oldCentre = CGPoint(x: r.midX, y: r.midY)
            let offset = rotateVector(CGVector(dx: local.midX - oldCentre.x, dy: local.midY - oldCentre.y),
                                      degrees: rotation)
            local.origin = CGPoint(x: oldCentre.x + offset.dx - local.width / 2,
                                   y: oldCentre.y + offset.dy - local.height / 2)
        }
        return ResizeResult(rect: local, guides: guides)
    }

    // MARK: Rotate

    /// The rotation after dragging the knob from `start` to `current`: the start rotation plus
    /// the angle swept about the box's centre, normalized to (-180, 180]. ⇧ (`snapToStep`) snaps
    /// to 15°; otherwise it snaps to 0/90/180/270 within 2°.
    static func rotation(of box: EditableBox, from start: CGPoint, to current: CGPoint, snapToStep: Bool) -> Double {
        let c = CGPoint(x: box.rect.midX, y: box.rect.midY)
        let a0 = atan2(Double(start.y - c.y), Double(start.x - c.x))
        let a1 = atan2(Double(current.y - c.y), Double(current.x - c.x))
        let base = box.rotationDegrees.isFinite ? box.rotationDegrees : 0
        let raw = normalizedDegrees(base + (a1 - a0) * 180 / .pi)
        let snapped = snapToStep
            ? Snapping.snapAngle(raw, step: shiftRotationStep, threshold: shiftRotationStep / 2)
            : Snapping.snapAngle(raw, step: 90, threshold: rightAngleSnap)
        return normalizedDegrees(snapped)
    }

    /// `degrees` in (-180, 180].
    static func normalizedDegrees(_ degrees: Double) -> Double {
        guard degrees.isFinite else { return 0 }
        var d = degrees.truncatingRemainder(dividingBy: 360)
        if d <= -180 { d += 360 }
        if d > 180 { d -= 360 }
        return d == 0 ? 0 : d // no -0
    }

    // MARK: Cursors

    /// The handle a resize cursor should point like, for a box rotated by `rotationDegrees`
    /// (rounded to the nearest 45°).
    static func cursorHandle(for handle: BoxHandle, rotationDegrees: Double) -> BoxHandle {
        let ring: [BoxHandle] = [.top, .topRight, .right, .bottomRight, .bottom, .bottomLeft, .left, .topLeft]
        guard let index = ring.firstIndex(of: handle) else { return handle }
        let steps = Int((normalizedDegrees(rotationDegrees) / 45).rounded())
        return ring[((index + steps) % 8 + 8) % 8]
    }

    // MARK: Helpers

    private static func isUnrotated(_ degrees: Double) -> Bool {
        normalizedDegrees(degrees) == 0
    }

    private static func rotateVector(_ v: CGVector, degrees: Double) -> CGVector {
        guard degrees != 0 else { return v }
        let a = CGFloat(degrees) * .pi / 180
        let cs = cos(a), sn = sin(a)
        return CGVector(dx: v.dx * cs - v.dy * sn, dy: v.dx * sn + v.dy * cs)
    }
}
