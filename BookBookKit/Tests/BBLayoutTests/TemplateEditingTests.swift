import BBModel
import CoreGraphics
import Testing
@testable import BBLayout

@Suite("Template editing geometry")
struct TemplateEditingTests {
    static func near(_ a: CGFloat, _ b: CGFloat, _ tol: CGFloat = 1e-6) -> Bool { abs(a - b) <= tol }
    static func near(_ a: CGPoint, _ b: CGPoint, _ tol: CGFloat = 1e-6) -> Bool { near(a.x, b.x, tol) && near(a.y, b.y, tol) }

    static let setup = PageSetup(trimSize: PointSize(width: 300, height: 200), orientation: .landscape,
                                 margins: EdgeInsetsPt(top: 10, leading: 20, bottom: 30, trailing: 40))
    static let id1 = BoxID("00000000-0000-0000-0000-000000000001")
    static let id2 = BoxID("00000000-0000-0000-0000-000000000002")
    static let id3 = BoxID("00000000-0000-0000-0000-000000000003")

    // MARK: Normalized frames and safe areas

    @Test func trimRectRoundTripSingleAndSpread() {
        let frame = NormalizedRect(x: 0.1, y: 0.2, width: 0.5, height: 0.25)
        for kind in [TemplateKind.single, .spread] {
            let g = PageGeometry(setup: Self.setup, kind: kind)
            let rect = g.trimRect(for: frame)
            #expect(Self.near(rect.width, CGFloat(0.5) * g.trimSize.width))
            let back = g.normalizedFrame(for: rect)
            #expect(Self.near(CGFloat(back.x), 0.1) && Self.near(CGFloat(back.width), 0.5))
            #expect(Self.near(CGFloat(back.y), 0.2) && Self.near(CGFloat(back.height), 0.25))
        }
        #expect(PageGeometry(setup: Self.setup, kind: .spread).trimSize.width == 600)
    }

    @Test func trimRectIgnoresBleedAndIsNotClamped() {
        var setup = Self.setup
        setup.bleedEnabled = true
        setup.bleedAmount = 9
        let g = PageGeometry(setup: setup)
        let frame = NormalizedRect(x: -0.1, y: 0, width: 1.2, height: 1)
        #expect(g.trimRect(for: frame) == CGRect(x: -30, y: 0, width: 360, height: 200))
    }

    @Test func safeAreasSingle() {
        let g = PageGeometry(setup: Self.setup)
        #expect(g.pageSafeAreas == [CGRect(x: 20, y: 10, width: 240, height: 160)])
    }

    @Test func safeAreasSpreadUseMarginsPerHalf() {
        let g = PageGeometry(setup: Self.setup, kind: .spread)
        #expect(g.pageSafeAreas == [CGRect(x: 20, y: 10, width: 240, height: 160),
                                    CGRect(x: 320, y: 10, width: 240, height: 160)])
        #expect(g.foldX == 300)
    }

    @Test func safeAreasKeepBleedMinimumInset() {
        var setup = Self.setup
        setup.bleedEnabled = true
        setup.margins = EdgeInsetsPt(all: 2)
        let areas = PageGeometry(setup: setup, kind: .spread).pageSafeAreas
        #expect(areas[0] == CGRect(x: 9, y: 9, width: 282, height: 182))
        #expect(areas[1] == CGRect(x: 309, y: 9, width: 282, height: 182))
    }

    // MARK: Hit testing

    @Test func unrotateInvertsPositiveClockwiseRotation() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 20)
        let centre = CGPoint(x: 50, y: 10)
        // A point below the centre is the right-hand point turned 90 deg clockwise (y down).
        let p = BoxHitTesting.unrotate(CGPoint(x: 50, y: 60), rect: rect, rotationDegrees: 90)
        #expect(Self.near(p, CGPoint(x: 100, y: 10)))
        #expect(Self.near(BoxHitTesting.unrotate(centre, rect: rect, rotationDegrees: 33), centre))
    }

    @Test func rotatedBoxHitTest() {
        let box = EditableBox(id: Self.id1, rect: CGRect(x: 0, y: 0, width: 100, height: 20), rotationDegrees: 90)
        // Rotated 90 degrees it occupies x 40...60, y -40...60.
        #expect(BoxHitTesting.box(at: CGPoint(x: 50, y: 55), in: [box]) == Self.id1)
        #expect(BoxHitTesting.box(at: CGPoint(x: 90, y: 10), in: [box]) == nil)
        let bounds = BoxHitTesting.rotatedBounds(box)
        #expect(Self.near(bounds.minX, 40) && Self.near(bounds.maxX, 60))
        #expect(Self.near(bounds.minY, -40) && Self.near(bounds.maxY, 60))
    }

    @Test func topmostWins() {
        let a = EditableBox(id: Self.id1, rect: CGRect(x: 0, y: 0, width: 100, height: 100), rotationDegrees: 0)
        let b = EditableBox(id: Self.id2, rect: CGRect(x: 50, y: 50, width: 100, height: 100), rotationDegrees: 10)
        #expect(BoxHitTesting.box(at: CGPoint(x: 80, y: 80), in: [a, b]) == Self.id2)
        #expect(BoxHitTesting.box(at: CGPoint(x: 80, y: 80), in: [b, a]) == Self.id1)
        #expect(BoxHitTesting.box(at: CGPoint(x: 10, y: 10), in: [a, b]) == Self.id1)
        #expect(BoxHitTesting.box(at: CGPoint(x: 500, y: 500), in: [a, b]) == nil)
    }

    @Test func handlesSitOnRotatedOutline() {
        let box = EditableBox(id: Self.id1, rect: CGRect(x: 0, y: 0, width: 100, height: 20), rotationDegrees: 90)
        // Top-left corner (0,0) rotates about (50,10) to (60,-40).
        let tl = BoxHitTesting.position(of: .topLeft, of: box, rotationKnobOffset: 20)
        #expect(Self.near(tl, CGPoint(x: 60, y: -40)))
        #expect(BoxHitTesting.handle(at: CGPoint(x: 61, y: -39), of: box, tolerance: 4, rotationKnobOffset: 20) == .topLeft)
        #expect(BoxHitTesting.handle(at: CGPoint(x: 0, y: 0), of: box, tolerance: 4, rotationKnobOffset: 20) == nil)
    }

    @Test func rotationKnobSitsAboveTopMidpointAndRotates() {
        var box = EditableBox(id: Self.id1, rect: CGRect(x: 0, y: 100, width: 100, height: 50), rotationDegrees: 0)
        #expect(Self.near(BoxHitTesting.position(of: .rotation, of: box, rotationKnobOffset: 24), CGPoint(x: 50, y: 76)))
        #expect(BoxHitTesting.handle(at: CGPoint(x: 51, y: 77), of: box, tolerance: 5, rotationKnobOffset: 24) == .rotation)
        box.rotationDegrees = 90
        // Top midpoint (50,100) about the centre (50,125) is (75,125); the knob is 24 further out.
        #expect(Self.near(BoxHitTesting.position(of: .rotation, of: box, rotationKnobOffset: 24), CGPoint(x: 99, y: 125)))
        #expect(BoxHitTesting.handle(at: CGPoint(x: 99, y: 126), of: box, tolerance: 5, rotationKnobOffset: 24) == .rotation)
    }

    @Test func movingEdges() {
        #expect(BoxHandle.topLeft.movingEdges == [.top, .leading])
        #expect(BoxHandle.right.movingEdges == [.trailing])
        #expect(BoxHandle.rotation.movingEdges.isEmpty)
    }

    // MARK: Snapping

    @Test func snapTargetsSingleHaveNoDuplicates() {
        let g = PageGeometry(setup: Self.setup)
        let other = EditableBox(id: Self.id1, rect: CGRect(x: 20, y: 10, width: 130, height: 50), rotationDegrees: 0)
        let t = SnapTargets.make(geometry: g, isSpread: false, others: [other, other])
        #expect(t.xs.count == Set(t.xs).count)
        #expect(t.ys.count == Set(t.ys).count)
        for x in [0, 20, 150, 260, 300] as [CGFloat] { #expect(t.xs.contains(x)) }
        for y in [0, 10, 35, 100, 170, 200] as [CGFloat] { #expect(t.ys.contains(y)) }
    }

    @Test func snapTargetsSpreadIncludeFoldAndBothHalves() {
        let g = PageGeometry(setup: Self.setup, kind: .spread)
        let t = SnapTargets.make(geometry: g, isSpread: true, others: [])
        for x in [0, 20, 150, 260, 300, 320, 450, 560, 600] as [CGFloat] { #expect(t.xs.contains(x)) }
    }

    @Test func snapMovePrefersClosestAndReportsGuides() {
        let t = SnapTargets(xs: [100, 104], ys: [50])
        let r = Snapping.snapMove(CGRect(x: 101, y: 47, width: 20, height: 10), to: t, threshold: 5)
        #expect(r.rect.minX == 100)               // 1 away beats 3 away
        #expect(r.rect.size == CGSize(width: 20, height: 10))
        #expect(r.rect.midY == 50)                // centre (2 away) beats top (3 away)
        #expect(r.guides.contains { $0.axis == .vertical && $0.position == 100 })
        #expect(r.guides.contains { $0.axis == .horizontal && $0.position == 50 })
    }

    @Test func snapMoveOutsideThresholdIsUnchanged() {
        let t = SnapTargets(xs: [100], ys: [100])
        let rect = CGRect(x: 10, y: 10, width: 20, height: 20)
        let r = Snapping.snapMove(rect, to: t, threshold: 5)
        #expect(r.rect == rect)
        #expect(r.guides.isEmpty)
    }

    @Test func snapMoveSnapsCentre() {
        let t = SnapTargets(xs: [150], ys: [])
        let r = Snapping.snapMove(CGRect(x: 100, y: 0, width: 98, height: 10), to: t, threshold: 3)
        #expect(r.rect.midX == 150)
    }

    @Test func snapResizeMovesOnlyNamedEdges() {
        let t = SnapTargets(xs: [10, 200], ys: [10])
        let rect = CGRect(x: 12, y: 12, width: 186, height: 80)
        let r = Snapping.snapResize(rect, movingEdges: [.trailing], to: t, threshold: 5, minSize: 20)
        #expect(r.rect.minX == 12 && r.rect.maxX == 200 && r.rect.minY == 12 && r.rect.height == 80)
        #expect(r.guides.count == 1 && r.guides[0].axis == .vertical && r.guides[0].position == 200)
        let both = Snapping.snapResize(rect, movingEdges: [.leading, .top], to: t, threshold: 5, minSize: 20)
        #expect(both.rect.minX == 10 && both.rect.minY == 10 && both.rect.maxX == 198 && both.rect.maxY == 92)
        #expect(both.guides.count == 2)
    }

    @Test func snapResizeRespectsMinSize() {
        let t = SnapTargets(xs: [100], ys: [])
        // Snapping the trailing edge to 100 would leave width 10 < minSize 30: skipped.
        let rect = CGRect(x: 90, y: 0, width: 13, height: 10)
        let r = Snapping.snapResize(rect, movingEdges: [.trailing], to: t, threshold: 5, minSize: 30)
        #expect(r.rect == rect)
        #expect(r.guides.isEmpty)
    }

    @Test func snapAngle() {
        #expect(Snapping.snapAngle(43, step: 45, threshold: 3) == 45)
        #expect(Snapping.snapAngle(48.5, step: 45, threshold: 3) == 48.5)
        #expect(Snapping.snapAngle(-89, step: 15, threshold: 2) == -90)
        #expect(Snapping.snapAngle(358, step: 90, threshold: 3) == 360)
    }

    // MARK: Align and distribute

    static let frames: [BoxID: NormalizedRect] = [
        id1: NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.1),
        id2: NormalizedRect(x: 0.5, y: 0.4, width: 0.3, height: 0.2),
        id3: NormalizedRect(x: 0.9, y: 0.7, width: 0.05, height: 0.1),
    ]

    @Test func alignToUnion() {
        let l = Arrangement.align(Self.frames, .left, reference: nil)
        #expect(l.values.allSatisfy { $0.x == 0.1 })
        let r = Arrangement.align(Self.frames, .right, reference: nil)
        #expect(r.values.allSatisfy { abs($0.maxX - 0.95) < 1e-9 })
        let c = Arrangement.align(Self.frames, .horizontalCenter, reference: nil)
        #expect(c.values.allSatisfy { abs($0.x + $0.width / 2 - 0.525) < 1e-9 })
        let t = Arrangement.align(Self.frames, .top, reference: nil)
        #expect(t.values.allSatisfy { $0.y == 0.1 })
        let b = Arrangement.align(Self.frames, .bottom, reference: nil)
        #expect(b.values.allSatisfy { abs($0.maxY - 0.8) < 1e-9 })
        let m = Arrangement.align(Self.frames, .verticalCenter, reference: nil)
        #expect(m.values.allSatisfy { abs($0.y + $0.height / 2 - 0.45) < 1e-9 })
        #expect(l[Self.id2]?.width == 0.3)
    }

    @Test func alignToReference() {
        let ref = NormalizedRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9)
        let one = [Self.id2: Self.frames[Self.id2]!]
        let r = Arrangement.align(one, .horizontalCenter, reference: ref)
        #expect(abs(r[Self.id2]!.x - 0.35) < 1e-9)
        #expect(Arrangement.align(one, .left, reference: ref)[Self.id2]!.x == 0.05)
    }

    @Test func distributeEqualGaps() {
        let d = Arrangement.distribute(Self.frames, axis: .horizontal)
        let a = d[Self.id1]!, b = d[Self.id2]!, c = d[Self.id3]!
        #expect(a == Self.frames[Self.id1] && c == Self.frames[Self.id3])
        #expect(abs((b.x - a.maxX) - (c.x - b.maxX)) < 1e-9)
        let v = Arrangement.distribute(Self.frames, axis: .vertical)
        #expect(abs((v[Self.id2]!.y - v[Self.id1]!.maxY) - (v[Self.id3]!.y - v[Self.id2]!.maxY)) < 1e-9)
    }

    @Test func distributeFewerThanThreeUnchanged() {
        let two = [Self.id1: Self.frames[Self.id1]!, Self.id2: Self.frames[Self.id2]!]
        #expect(Arrangement.distribute(two, axis: .horizontal) == two)
    }
}
