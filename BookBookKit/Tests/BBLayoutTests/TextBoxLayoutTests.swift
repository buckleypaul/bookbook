import BBModel
import CoreGraphics
import Testing
@testable import BBLayout

@MainActor
@Suite("TextBoxLayout")
struct TextBoxLayoutTests {
    init() { LayoutFixtures.registerFonts() }

    @Test func shortTextFits() {
        let layout = TextBoxLayout(text: RichText(plain: LayoutFixtures.sentences),
                                   typography: LayoutFixtures.typography, containerSize: CGSize(width: 240, height: 120))
        #expect(!layout.isOverflowing)
        #expect(layout.usedHeight > 0)
        #expect(layout.usedHeight <= 120)
    }

    @Test func longTextOverflows() {
        let long = Array(repeating: LayoutFixtures.sentences, count: 12).joined(separator: " ")
        let layout = TextBoxLayout(text: RichText(plain: long),
                                   typography: LayoutFixtures.typography, containerSize: CGSize(width: 240, height: 120))
        #expect(layout.isOverflowing)
    }

    @Test func emptyTextDoesNotOverflow() {
        let layout = TextBoxLayout(text: .empty, typography: LayoutFixtures.typography,
                                   containerSize: CGSize(width: 100, height: 20))
        #expect(!layout.isOverflowing)
    }

    @Test func rendererReportsOverflowingBoxes() {
        let ref = ImageRef(sha256: "aa", contentType: "public.png")
        let fits = LayoutFixtures.content(imageRef: ref, imagePixels: PixelSize(width: 4, height: 4))
        let renderer = PageRenderer(images: DictionaryImageSource())
        #expect(renderer.overflowingTextBoxes(page: fits.storyPages[0], in: fits).isEmpty)

        let long = Array(repeating: LayoutFixtures.sentences, count: 12).joined(separator: " ")
        let over = LayoutFixtures.content(imageRef: ref, imagePixels: PixelSize(width: 4, height: 4),
                                          text: RichText(plain: long))
        #expect(renderer.overflowingTextBoxes(page: over.storyPages[0], in: over) == [LayoutFixtures.textBoxID])
    }
}
