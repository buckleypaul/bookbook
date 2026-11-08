import AppKit
import BBLayout
import BBModel
import Foundation
import Testing
@testable import BBUI

/// Phase 7: both editors show the bleed and keep working in trim-space page points; the
/// template editor edits render rects (bleed-extended) and stores trim-normalized frames, and
/// rotation pivots on the render rect's centre everywhere.
@MainActor
struct CanvasBleedGeometryTests {
    static func setup(bleed: Bool) -> PageSetup {
        PageSetup(trimSize: PointSize(width: 600, height: 800), orientation: .portrait,
                  margins: EdgeInsetsPt(all: 36), bleedEnabled: bleed)
    }

    static let fullBleed = Box(frame: NormalizedRect(x: 0, y: 0, width: 1, height: 0.5), rotationDegrees: 30,
                               bleedEdges: [.top, .leading, .trailing], content: .image)

    static func imageSource() -> ImageCache {
        ImageCache(maxPixelSize: nil) { _ in URL(fileURLWithPath: "/nonexistent") }
    }

    // MARK: Template editor maths

    @Test func editableBoxesUseRenderRectsAndFramesRoundTrip() {
        let geometry = PageGeometry(setup: Self.setup(bleed: true))
        let template = Template(name: "T", kind: .single, boxes: [Self.fullBleed])
        let box = LayoutEditingMath.editableBoxes(template, geometry: geometry)[0]
        #expect(box.rect == CGRect(x: -9, y: -9, width: 618, height: 409))
        #expect(box.rect == geometry.renderRect(for: Self.fullBleed))
        #expect(box.rotationDegrees == 30)

        // Moving the render rect by (12, 40) moves the stored frame by the same amount.
        let pushed = geometry.pushedBleedEdges(for: Self.fullBleed)
        let frame = LayoutEditingMath.frame(forRender: box.rect.offsetBy(dx: 12, dy: 40), pushedEdges: pushed,
                                            geometry: geometry)
        #expect(abs(frame.x - 12.0 / 600) < 1e-12 && abs(frame.y - 40.0 / 800) < 1e-12)
        #expect(abs(frame.width - 1) < 1e-12 && abs(frame.height - 0.5) < 1e-12)
        // An unchanged rect gives back the stored frame.
        #expect(LayoutEditingMath.frame(forRender: box.rect, pushedEdges: pushed, geometry: geometry)
            == Self.fullBleed.frame)

        // Bleed off: render rect is the trim rect.
        let off = PageGeometry(setup: Self.setup(bleed: false))
        #expect(LayoutEditingMath.editableBoxes(template, geometry: off)[0].rect == CGRect(x: 0, y: 0, width: 600, height: 400))
    }

    @Test func snapTargetsIncludeTheBleedEdgesOnlyWithBleedOn() {
        let on = LayoutEditingMath.snapTargets(geometry: PageGeometry(setup: Self.setup(bleed: true)), others: [])
        #expect(on.xs.contains(-9) && on.xs.contains(609) && on.ys.contains(-9) && on.ys.contains(809))
        #expect(on.xs.contains(0) && on.xs.contains(600))
        #expect(on.xs == on.xs.sorted() && on.ys == on.ys.sorted())
        let off = LayoutEditingMath.snapTargets(geometry: PageGeometry(setup: Self.setup(bleed: false)), others: [])
        #expect(!off.xs.contains(-9) && !off.ys.contains(809))
    }

    @Test func rotatedFullBleedBoxHitTestsAboutTheRenderCentre() {
        // The renderer rotates about the render rect's centre; the editor's box must too.
        let geometry = PageGeometry(setup: Self.setup(bleed: true))
        let template = Template(name: "T", kind: .single, boxes: [Self.fullBleed])
        let box = LayoutEditingMath.editableBoxes(template, geometry: geometry)[0]
        let render = geometry.renderRect(for: Self.fullBleed)
        #expect(CGPoint(x: box.rect.midX, y: box.rect.midY) == CGPoint(x: render.midX, y: render.midY))
        // A render-rect corner rotated about the render centre is where the handle sits.
        let t = CGAffineTransform(translationX: render.midX, y: render.midY).rotated(by: .pi / 6)
            .translatedBy(x: -render.midX, y: -render.midY)
        let corner = CGPoint(x: render.maxX, y: render.maxY).applying(t)
        let handle = BoxHitTesting.position(of: .bottomRight, of: box, rotationKnobOffset: 20)
        #expect(hypot(handle.x - corner.x, handle.y - corner.y) < 1e-9)
    }

    // MARK: Page canvas

    @Test func pageCanvasShowsTheBleedAndKeepsTrimSpacePoints() throws {
        var content = Fixtures.book()
        content.style.pageSetup = Self.setup(bleed: true)
        let page = Fixtures.firstPage(content)
        let templateID = try #require(content.pages[page]?.templateID)
        content.templates[templateID]?.boxes = [Self.fullBleed]
        let view = CanvasView(frame: CGRect(x: 0, y: 0, width: 666, height: 866))
        view.update(content: content, pageID: page, selectedImageBox: nil, imageSource: Self.imageSource())

        let scene = try #require(view.controller?.scene)
        #expect(scene.showsBleed)
        #expect(scene.sheetRect == CGRect(x: -9, y: -9, width: 618, height: 818))
        // 618×818 fits 618×818 (margin 24) at scale 1; the trim's top-left is 9 pt in.
        let transform = try #require(view.transform)
        #expect(abs(transform.scale - 1) < 1e-9)
        #expect(transform.toView(CGPoint(x: -9, y: -9)) == CGPoint(x: 24, y: 24))
        #expect(transform.toPage(CGPoint(x: 33, y: 33)) == .zero)

        // The box's rect on the canvas is its render rect, and a click in the bleed hits it.
        #expect(view.boxRects.first?.rect == CGRect(x: -9, y: -9, width: 618, height: 409))
        let centre = CGPoint(x: 300, y: 195.5)
        #expect(CanvasHitTest.box(at: centre, in: view.boxRects)?.id == Self.fullBleed.id)

        // Bleed off: the old behaviour (trim fitted, no bleed).
        content.style.pageSetup = Self.setup(bleed: false)
        view.update(content: content, pageID: page, selectedImageBox: nil, imageSource: Self.imageSource())
        let plain = try #require(view.controller?.scene)
        #expect(!plain.showsBleed)
        #expect(plain.sheetRect == CGRect(x: 0, y: 0, width: 600, height: 800))
        #expect(view.boxRects.first?.rect == CGRect(x: 0, y: 0, width: 600, height: 400))
    }

    @Test func spreadPageDoesNotBleedAtTheFold() throws {
        var content = Fixtures.book()
        content.style.pageSetup = Self.setup(bleed: true)
        let page = Fixtures.firstPage(content)
        let left = Box(frame: NormalizedRect(x: 0, y: 0, width: 0.5, height: 1), bleedEdges: .all, content: .image)
        let spread = Template(name: "Spread", kind: .spread, boxes: [left])
        content.templates[spread.id] = spread
        content.pages[page]?.templateID = spread.id
        let view = CanvasView(frame: CGRect(x: 0, y: 0, width: 1300, height: 900))
        view.update(content: content, pageID: page, selectedImageBox: nil, imageSource: Self.imageSource())
        let scene = try #require(view.controller?.scene)
        #expect(scene.showsFold && scene.geometry.isSpread)
        #expect(scene.sheetRect == CGRect(x: -9, y: -9, width: 1218, height: 818))
        #expect(view.boxRects.first?.rect == CGRect(x: -9, y: -9, width: 609, height: 818))
    }
}
