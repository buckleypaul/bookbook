import BBLayout
import BBModel
import CoreGraphics
import Foundation
import Testing
@testable import BBUI

/// The template editor's drag maths (pure; never touches `TemplateEditorModel`).
struct LayoutEditingMathTests {
    private let a = BoxID(), b = BoxID()

    private func close(_ r: CGRect, _ e: CGRect, _ tolerance: CGFloat = 1e-6) -> Bool {
        abs(r.minX - e.minX) < tolerance && abs(r.minY - e.minY) < tolerance
            && abs(r.width - e.width) < tolerance && abs(r.height - e.height) < tolerance
    }

    // MARK: Clicks

    @Test func clickSelection() {
        // Plain click: selects just the box; on a selected box keeps the group (to move it).
        #expect(LayoutEditingMath.click(on: a, selection: [b], shift: false) == ([a], true))
        #expect(LayoutEditingMath.click(on: a, selection: [a, b], shift: false) == ([a, b], true))
        // ⇧ toggles; moving only if the box is now selected.
        #expect(LayoutEditingMath.click(on: a, selection: [b], shift: true) == ([a, b], true))
        #expect(LayoutEditingMath.click(on: a, selection: [a, b], shift: true) == ([b], false))
        // Empty space deselects (⇧ keeps the selection).
        #expect(LayoutEditingMath.click(on: nil, selection: [a], shift: false) == ([], false))
        #expect(LayoutEditingMath.click(on: nil, selection: [a], shift: true) == ([a], false))
    }

    // MARK: Move

    @Test func moveSnapsTheGroupAndShiftsEveryBoxTheSame() {
        let targets = SnapTargets(xs: [0, 100], ys: [0, 100])
        let boxes = [EditableBox(id: a, rect: CGRect(x: 10, y: 10, width: 20, height: 20), rotationDegrees: 0),
                     EditableBox(id: b, rect: CGRect(x: 40, y: 50, width: 10, height: 10), rotationDegrees: 0)]
        // Group bounds minX 10 → 2: within 3 of 0, so it snaps to 0 (extra −2). y doesn't snap.
        let snapped = LayoutEditingMath.move(boxes, by: CGVector(dx: -8, dy: 3), targets: targets, threshold: 3)
        #expect(snapped.rects[a] == CGRect(x: 0, y: 13, width: 20, height: 20))
        #expect(snapped.rects[b] == CGRect(x: 30, y: 53, width: 10, height: 10))
        #expect(snapped.guides.map(\.axis) == [.vertical])
        #expect(snapped.guides.first?.position == 0)

        // Snapping off (⌘ held or the toggle): the raw delta.
        let free = LayoutEditingMath.move(boxes, by: CGVector(dx: -8, dy: 3), targets: nil, threshold: 3)
        #expect(free.rects[a] == CGRect(x: 2, y: 13, width: 20, height: 20))
        #expect(free.guides.isEmpty)
    }

    @Test func moveSnapsARotatedBoxByItsRotatedBounds() throws {
        // 20×20 at 45°: rotated bounds reach 10√2 from the centre (50, 50).
        let box = EditableBox(id: a, rect: CGRect(x: 40, y: 40, width: 20, height: 20), rotationDegrees: 45)
        let halfDiagonal = 10 * CGFloat(2).squareRoot()
        let result = LayoutEditingMath.move([box], by: CGVector(dx: -34, dy: 0),
                                            targets: SnapTargets(xs: [0], ys: []), threshold: 3)
        let rect = try #require(result.rects[a])
        // The rotated left corner lands on x = 0.
        #expect(abs(rect.midX - halfDiagonal) < 1e-9)
        #expect(rect.size == box.rect.size)
    }

    // MARK: Resize

    @Test func resizeOfARotatedBoxWorksInItsLocalFrame() {
        // 100×50 rotated 90° clockwise: its local +x points down the page.
        let box = EditableBox(id: a, rect: CGRect(x: 0, y: 0, width: 100, height: 50), rotationDegrees: 90)
        let leftBefore = BoxHitTesting.position(of: .left, of: box, rotationKnobOffset: 0)
        let start = BoxHitTesting.position(of: .right, of: box, rotationKnobOffset: 0)
        let result = LayoutEditingMath.resize(box, handle: .right, from: start,
                                              to: CGPoint(x: start.x, y: start.y + 20),
                                              keepAspect: false, targets: nil, threshold: 3)
        #expect(close(result.rect, CGRect(x: -10, y: 10, width: 120, height: 50)))
        // The opposite edge stays put on the page.
        let resized = EditableBox(id: a, rect: result.rect, rotationDegrees: 90)
        let leftAfter = BoxHitTesting.position(of: .left, of: resized, rotationKnobOffset: 0)
        #expect(abs(leftAfter.x - leftBefore.x) < 1e-9 && abs(leftAfter.y - leftBefore.y) < 1e-9)

        // Moving the mouse along the box's local y doesn't change a right-edge resize.
        let sideways = LayoutEditingMath.resize(box, handle: .right, from: start,
                                                to: CGPoint(x: start.x - 30, y: start.y),
                                                keepAspect: false, targets: nil, threshold: 3)
        #expect(close(sideways.rect, box.rect))
    }

    @Test func rotatedResizeIgnoresSnapping() {
        let box = EditableBox(id: a, rect: CGRect(x: 0, y: 0, width: 100, height: 50), rotationDegrees: 10)
        let targets = SnapTargets(xs: Array(stride(from: 0, through: 200, by: 1)), ys: [])
        let snapped = LayoutEditingMath.resize(box, handle: .right, from: CGPoint(x: 100, y: 25),
                                               to: CGPoint(x: 113.3, y: 25), keepAspect: false,
                                               targets: targets, threshold: 3)
        let free = LayoutEditingMath.resize(box, handle: .right, from: CGPoint(x: 100, y: 25),
                                            to: CGPoint(x: 113.3, y: 25), keepAspect: false,
                                            targets: nil, threshold: 3)
        #expect(snapped == free)
    }

    @Test func unrotatedResizeSnapsTheMovingEdge() {
        let box = EditableBox(id: a, rect: CGRect(x: 0, y: 0, width: 100, height: 50), rotationDegrees: 0)
        let result = LayoutEditingMath.resize(box, handle: .right, from: CGPoint(x: 100, y: 25),
                                              to: CGPoint(x: 118, y: 40), keepAspect: false,
                                              targets: SnapTargets(xs: [0, 120], ys: [0, 52]), threshold: 3)
        // Right edge 118 → 120; the bottom isn't a moving edge, so 52 is ignored.
        #expect(result.rect == CGRect(x: 0, y: 0, width: 120, height: 50))
        #expect(result.guides.map(\.position) == [120])
    }

    @Test func aspectLockedCornerResize() {
        let box = EditableBox(id: a, rect: CGRect(x: 0, y: 0, width: 100, height: 50), rotationDegrees: 0)
        // Bottom-right: width grows more (×1.5 vs ×1.2), so height follows it.
        let br = LayoutEditingMath.resize(box, handle: .bottomRight, from: CGPoint(x: 100, y: 50),
                                          to: CGPoint(x: 150, y: 60), keepAspect: true,
                                          targets: SnapTargets(xs: [151], ys: [61]), threshold: 3)
        #expect(br.rect == CGRect(x: 0, y: 0, width: 150, height: 75))
        #expect(br.guides.isEmpty)
        // Top-left: height grows more, width follows; the bottom-right corner stays put.
        let tl = LayoutEditingMath.resize(box, handle: .topLeft, from: .zero, to: CGPoint(x: -10, y: -40),
                                          keepAspect: true, targets: nil, threshold: 3)
        #expect(tl.rect == CGRect(x: -80, y: -40, width: 180, height: 90))
        // Without ⇧ the corner moves freely.
        let free = LayoutEditingMath.resize(box, handle: .bottomRight, from: CGPoint(x: 100, y: 50),
                                            to: CGPoint(x: 150, y: 60), keepAspect: false, targets: nil, threshold: 3)
        #expect(free.rect == CGRect(x: 0, y: 0, width: 150, height: 60))
    }

    @Test func resizeKeepsAMinimumSize() {
        let box = EditableBox(id: a, rect: CGRect(x: 0, y: 0, width: 100, height: 50), rotationDegrees: 0)
        let result = LayoutEditingMath.resize(box, handle: .right, from: CGPoint(x: 100, y: 25),
                                              to: CGPoint(x: -50, y: 25), keepAspect: false, targets: nil, threshold: 3)
        #expect(result.rect == CGRect(x: 0, y: 0, width: LayoutEditingMath.minBoxSize, height: 50))
        let top = LayoutEditingMath.resize(box, handle: .top, from: CGPoint(x: 50, y: 0),
                                           to: CGPoint(x: 50, y: 200), keepAspect: false, targets: nil, threshold: 3)
        #expect(top.rect == CGRect(x: 0, y: 50 - LayoutEditingMath.minBoxSize, width: 100,
                                   height: LayoutEditingMath.minBoxSize))
    }

    // MARK: Rotate

    private let square = EditableBox(id: BoxID(), rect: CGRect(x: 0, y: 0, width: 100, height: 100),
                                     rotationDegrees: 0)

    /// A point at `degrees` (clockwise from the knob, i.e. from straight up) about the centre.
    private func point(at degrees: Double) -> CGPoint {
        let a = (degrees - 90) * .pi / 180
        return CGPoint(x: 50 + 100 * cos(a), y: 50 + 100 * sin(a))
    }

    @Test func rotationFollowsTheKnobAndSnapsToRightAngles() {
        let knob = point(at: 0)
        #expect(abs(LayoutEditingMath.rotation(of: square, from: knob, to: point(at: 5), snapToStep: false) - 5) < 1e-9)
        #expect(LayoutEditingMath.rotation(of: square, from: knob, to: point(at: 91.5), snapToStep: false) == 90)
        #expect(LayoutEditingMath.rotation(of: square, from: knob, to: point(at: -1.5), snapToStep: false) == 0)
        #expect(LayoutEditingMath.rotation(of: square, from: knob, to: point(at: 178.5), snapToStep: false) == 180)
        #expect(LayoutEditingMath.rotation(of: square, from: knob, to: point(at: 268.5), snapToStep: false) == -90)
        // Outside 2°: free.
        #expect(abs(LayoutEditingMath.rotation(of: square, from: knob, to: point(at: 87), snapToStep: false) - 87) < 1e-9)
    }

    @Test func rotationWithShiftSnapsTo15Degrees() {
        let knob = point(at: 0)
        #expect(LayoutEditingMath.rotation(of: square, from: knob, to: point(at: 20), snapToStep: true) == 15)
        #expect(LayoutEditingMath.rotation(of: square, from: knob, to: point(at: 25), snapToStep: true) == 30)
        #expect(LayoutEditingMath.rotation(of: square, from: knob, to: point(at: -50), snapToStep: true) == -45)
    }

    @Test func rotationIsRelativeToTheStartAndNormalized() {
        var tilted = square
        tilted.rotationDegrees = 170
        // Grabbing anywhere and sweeping +20° adds 20°: 190 → -170.
        let result = LayoutEditingMath.rotation(of: tilted, from: point(at: 33), to: point(at: 53), snapToStep: false)
        #expect(abs(result - -170) < 1e-9)
        #expect(LayoutEditingMath.normalizedDegrees(-180) == 180)
        #expect(LayoutEditingMath.normalizedDegrees(540) == 180)
        #expect(LayoutEditingMath.normalizedDegrees(-360) == 0)
    }

    @Test func cursorHandleFollowsRotation() {
        #expect(LayoutEditingMath.cursorHandle(for: .right, rotationDegrees: 0) == .right)
        #expect(LayoutEditingMath.cursorHandle(for: .right, rotationDegrees: 90) == .bottom)
        #expect(LayoutEditingMath.cursorHandle(for: .top, rotationDegrees: -45) == .topLeft)
        #expect(LayoutEditingMath.cursorHandle(for: .topLeft, rotationDegrees: 50) == .top)
    }
}
