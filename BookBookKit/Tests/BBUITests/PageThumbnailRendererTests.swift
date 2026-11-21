import BBModel
import CoreGraphics
import Foundation
import Testing
@testable import BBUI

@MainActor
struct PageThumbnailRendererTests {
    private let textBox = BoxID()

    private func content(pages: Int = 1) -> BookContent {
        let template = Template(name: "T", kind: .single, boxes: [
            Box(id: BoxID(), frame: NormalizedRect(x: 0.1, y: 0.1, width: 0.8, height: 0.5), content: .image),
            Box(id: textBox, frame: NormalizedRect(x: 0.1, y: 0.65, width: 0.8, height: 0.25),
                content: .text(TextBoxStyle())),
        ])
        return BookContent.makeNew(title: "B", storyTemplate: template,
                                   coverTemplate: Template(name: "C", kind: .cover, boxes: []),
                                   storyPageCount: pages, now: Date(timeIntervalSince1970: 0))
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

    @Test func manyEditsToOnePageKeepTheOthersCached() throws {
        var content = content(pages: 2)
        let pages = content.book.pageOrder
        let edited = try #require(pages.last), other = try #require(pages.dropLast().last)
        let thumbnails = renderer()
        let otherFirst = try #require(thumbnails.image(for: other, in: content, marks: [], pixelHeight: 40))
        for n in 0..<250 {
            content.pages[edited]?.text[textBox] = RichText(plain: "Draft \(n)")
            _ = thumbnails.image(for: edited, in: content, marks: [], pixelHeight: 40)
        }
        #expect(thumbnails.image(for: other, in: content, marks: [], pixelHeight: 40) === otherFirst)
    }

    @Test func aFontImportRedrawsEveryThumbnail() throws {
        var content = content()
        let page = try #require(content.book.pageOrder.first)
        content.pages[page]?.text[textBox] = RichText(plain: "Once upon a time")
        let thumbnails = renderer()
        let first = try #require(thumbnails.image(for: page, in: content, marks: [], pixelHeight: 40,
                                                  fontsRevision: 3))
        #expect(thumbnails.image(for: page, in: content, marks: [], pixelHeight: 40, fontsRevision: 3) === first)
        // Same page, but fonts were registered: the layout (and picture) may have used a fallback.
        let redrawn = try #require(thumbnails.image(for: page, in: content, marks: [], pixelHeight: 40,
                                                    fontsRevision: 4))
        #expect(redrawn !== first)
        #expect(thumbnails.image(for: page, in: content, marks: [], pixelHeight: 40, fontsRevision: 4) === redrawn)
    }
}
