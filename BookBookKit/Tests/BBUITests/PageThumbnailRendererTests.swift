import BBModel
import CoreGraphics
import Foundation
import Testing
@testable import BBUI

@MainActor
struct PageThumbnailRendererTests {
    private let textBox = BoxID()

    private func content() -> BookContent {
        let template = Template(name: "T", kind: .single, boxes: [
            Box(id: BoxID(), frame: NormalizedRect(x: 0.1, y: 0.1, width: 0.8, height: 0.5), content: .image),
            Box(id: textBox, frame: NormalizedRect(x: 0.1, y: 0.65, width: 0.8, height: 0.25),
                content: .text(TextBoxStyle())),
        ])
        return BookContent.makeNew(title: "B", storyTemplate: template,
                                   coverTemplate: Template(name: "C", kind: .cover, boxes: []),
                                   storyPageCount: 1, now: Date(timeIntervalSince1970: 0))
    }

    private func renderer() -> PageThumbnailRenderer {
        PageThumbnailRenderer(images: ImageCache(maxPixelSize: 64) { _ in URL(filePath: "/nonexistent") })
    }

    @Test func styleTextThatIsNeverDrawnKeepsTheCachedThumbnail() throws {
        var content = content()
        let page = try #require(content.book.pageOrder.first)
        let thumbnails = renderer()
        let first = try #require(thumbnails.image(for: page, in: content, marks: [], pixelHeight: 40))

        content.style.visualDescription = "Soft watercolour"
        content.style.negativeGuidance = "no frames"
        content.style.styleReferences = [Fixtures.ref]
        content.pages[page]?.isDone = true
        #expect(thumbnails.image(for: page, in: content, marks: [], pixelHeight: 40) === first)
    }

    @Test func drawnChangesRedraw() throws {
        var content = content()
        let page = try #require(content.book.pageOrder.first)
        let thumbnails = renderer()
        let first = try #require(thumbnails.image(for: page, in: content, marks: [], pixelHeight: 40))

        content.pages[page]?.text[textBox] = RichText(plain: "Once upon a time")
        let withText = try #require(thumbnails.image(for: page, in: content, marks: [], pixelHeight: 40))
        #expect(withText !== first)

        content.style.typography.color = RGBA(red: 1, green: 0, blue: 0)
        #expect(thumbnails.image(for: page, in: content, marks: [], pixelHeight: 40) !== withText)
    }
}
