import AppKit
import BBLayout
import BBModel
import Foundation
import Testing
@testable import BBUI

/// The page canvas draws spreads at double width (fold in the middle) and doesn't edit
/// title/author boxes in place (Phase 5 integration).
@MainActor
struct CanvasSpreadAndCoverTests {
    static let left = Box(frame: NormalizedRect(x: 0.05, y: 0.1, width: 0.4, height: 0.8), content: .image)
    static let right = Box(frame: NormalizedRect(x: 0.55, y: 0.1, width: 0.4, height: 0.8),
                           content: .text(TextBoxStyle()))
    static let spread = Template(name: "Spread", kind: .spread, boxes: [left, right])

    private func canvas(_ content: BookContent, page: PageID) -> CanvasView {
        let view = CanvasView(frame: CGRect(x: 0, y: 0, width: 1200, height: 600))
        view.update(content: content, pageID: page, selectedImageBox: nil,
                    imageSource: ImageCache(maxPixelSize: nil) { _ in URL(fileURLWithPath: "/nonexistent") })
        return view
    }

    @Test func spreadGeometryIsDoubleWidthWithFoldInTheMiddle() throws {
        var content = Fixtures.book(pages: 2)
        content.templates[Self.spread.id] = Self.spread
        let spreadPage = content.book.pageOrder[1]
        content.pages[spreadPage]?.templateID = Self.spread.id
        let trim = content.style.pageSetup.trimSize

        let view = canvas(content, page: spreadPage)
        let geometry = try #require(view.geometry)
        #expect(geometry.trimSize == CGSize(width: trim.width * 2, height: trim.height))
        #expect(Double(geometry.foldX) == trim.width)
        // Hit-testing uses the spread trim: the right-hand box sits right of the fold.
        let rightRect = try #require(view.boxRects.first { $0.box.id == Self.right.id }?.rect)
        #expect(rightRect.minX > geometry.foldX)
        let hit = CanvasHitTest.box(at: CGPoint(x: trim.width * 1.5, y: trim.height / 2), in: view.boxRects)
        #expect(hit?.id == Self.right.id)

        // A single page keeps the book's trim.
        let single = canvas(content, page: content.book.pageOrder[0])
        #expect(single.geometry?.trimSize == CGSize(width: trim.width, height: trim.height))
    }

    @Test func pageNumbersShownOnCanvas() {
        var content = Fixtures.book(pages: 2)
        content.style.pageNumbers = PageNumberStyle(enabled: true)
        #expect(canvas(content, page: content.book.pageOrder[1]).pageNumberMarks.map(\.text) == ["2"])
        #expect(canvas(content, page: content.book.coverPageID).pageNumberMarks.isEmpty)
    }

    @Test func boundBoxesOpenBookSettingsInsteadOfEditing() {
        let title = Box(frame: NormalizedRect(x: 0, y: 0, width: 1, height: 0.2), content: .text(TextBoxStyle()),
                        role: .title)
        let author = Box(frame: NormalizedRect(x: 0, y: 0.8, width: 1, height: 0.2), content: .text(TextBoxStyle()),
                         role: .author)
        let body = Box(frame: NormalizedRect(x: 0, y: 0.3, width: 1, height: 0.4), content: .text(TextBoxStyle()))
        for box in [title, author] {
            #expect(CanvasHitTest.click(on: box, clickCount: 1) == .selectText(box.id))
            #expect(CanvasHitTest.click(on: box, clickCount: 2) == .openBookSettings)
        }
        #expect(CanvasHitTest.click(on: body, clickCount: 1) == .editText(body.id))
        #expect(CanvasHitTest.click(on: body, clickCount: 2) == .editText(body.id))
        #expect(CanvasHitTest.click(on: Fixtures.imageBox, clickCount: 1) == .selectImage(Fixtures.imageBox.id))
        #expect(CanvasHitTest.click(on: nil, clickCount: 1) == .deselect)
    }
}
