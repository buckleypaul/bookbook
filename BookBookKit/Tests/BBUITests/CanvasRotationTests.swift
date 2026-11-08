import AppKit
import BBLayout
import BBModel
import Foundation
import Testing
@testable import BBUI

/// The page canvas honours box rotation when hit-testing, and lays text out with the box's
/// style overrides, like `PageRenderer` (Phase 6).
@MainActor
struct CanvasRotationTests {
    @Test func hitTestUsesTheRotatedOutline() {
        // 100×20 rotated 90° about (50, 10): it now spans x 40…60, y -40…60.
        let box = Box(frame: NormalizedRect(x: 0, y: 0, width: 1, height: 1), rotationDegrees: 90, content: .image)
        let boxes = [(box: box, rect: CGRect(x: 0, y: 0, width: 100, height: 20))]
        #expect(CanvasHitTest.box(at: CGPoint(x: 50, y: 50), in: boxes)?.id == box.id)  // outside the unrotated rect
        #expect(CanvasHitTest.box(at: CGPoint(x: 5, y: 10), in: boxes) == nil)          // inside it, outside the box
    }

    @Test func canvasHitTestsARotatedBoxOnThePage() throws {
        var content = Fixtures.book()
        let page = Fixtures.firstPage(content)
        let templateID = try #require(content.pages[page]?.templateID)
        let rotated = Box(frame: NormalizedRect(x: 0.1, y: 0.45, width: 0.8, height: 0.1), rotationDegrees: 90,
                          content: .image)
        content.templates[templateID]?.boxes = [rotated]
        let view = CanvasView(frame: CGRect(x: 0, y: 0, width: 800, height: 800))
        view.update(content: content, pageID: page, selectedImageBox: nil,
                    imageSource: ImageCache(maxPixelSize: nil) { _ in URL(fileURLWithPath: "/nonexistent") })
        let rect = try #require(view.boxRects.first?.rect)
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        // Along the rotated long axis (vertical), beyond the unrotated rect's height.
        #expect(CanvasHitTest.box(at: CGPoint(x: centre.x, y: centre.y + rect.height), in: view.boxRects)?.id
            == rotated.id)
        // Along the unrotated long axis: no longer the box.
        #expect(CanvasHitTest.box(at: CGPoint(x: rect.minX + 2, y: centre.y), in: view.boxRects) == nil)
    }

    @Test func textBoxTypographyAppliesTheBoxStyle() {
        let base = Fixtures.book().style.typography
        let styled = Box(frame: NormalizedRect(x: 0, y: 0, width: 1, height: 1),
                         content: .text(TextBoxStyle(fontSize: 31, alignment: .center,
                                                     color: RGBA(red: 1, green: 0, blue: 0, alpha: 1))))
        let typography = InlineTextEditor.typography(for: styled, base: base)
        #expect(typography == base.resolved(for: nil).applying(TextBoxStyle(fontSize: 31, alignment: .center,
                                                                              color: RGBA(red: 1, green: 0, blue: 0, alpha: 1))))
        #expect(typography.bodySize == 31)
        #expect(typography.alignment == .center)
        // No overrides: just the style guide's.
        let plain = Box(frame: NormalizedRect(x: 0, y: 0, width: 1, height: 1), content: .text(TextBoxStyle()))
        #expect(InlineTextEditor.typography(for: plain, base: base) == base)
    }

    @Test func fittingTransformKeepsTheTrimOriginAtPagePointZero() {
        // Trim 100×100 grown by 10 of bleed: fits 120×120 into 168×168 (margin 24) at scale 1.
        let t = CanvasTransform(viewSize: CGSize(width: 168, height: 168),
                                fitting: CGRect(x: -10, y: -10, width: 120, height: 120))
        #expect(abs(t.scale - 1) < 1e-9)
        #expect(t.origin == CGPoint(x: 34, y: 34))
        #expect(t.toView(CGPoint(x: -10, y: -10)) == CGPoint(x: 24, y: 24))
    }
}
