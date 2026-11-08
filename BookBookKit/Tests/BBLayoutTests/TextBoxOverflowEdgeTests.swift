import BBModel
import CoreGraphics
import Testing
@testable import BBLayout

@MainActor
@Suite("TextBoxLayout overflow edge cases")
struct TextBoxOverflowEdgeTests {
    init() { LayoutFixtures.registerFonts() }
    let typography = LayoutFixtures.typography

    func layout(_ text: String, width: CGFloat = 200, height: CGFloat) -> TextBoxLayout {
        TextBoxLayout(text: RichText(plain: text), typography: typography,
                      containerSize: CGSize(width: width, height: height))
    }

    @Test func emptyTextInZeroHeightBox() {
        #expect(!layout("", height: 0).isOverflowing)
        #expect(!TextBoxLayout(text: .empty, typography: typography, containerSize: .zero).isOverflowing)
    }

    @Test func exactFitDoesNotOverflowButOneLineLessDoes() {
        let natural = layout("one\ntwo\nthree", height: 1000)
        let lineHeight = natural.usedHeight / 3
        #expect(!layout("one\ntwo\nthree", height: natural.usedHeight).isOverflowing)
        #expect(layout("one\ntwo\nthree", height: natural.usedHeight - lineHeight).isOverflowing)
        #expect(!layout("one\ntwo\nthree", height: natural.usedHeight - 0.25).isOverflowing)
    }

    @Test func oneLineTooMany() {
        let two = layout("one\ntwo", height: 1000)
        #expect(!layout("one\ntwo", height: two.usedHeight).isOverflowing)
        #expect(layout("one\ntwo\nthree", height: two.usedHeight).isOverflowing)
    }

    @Test func trailingNewlineCountsAsALine() {
        let plain = layout("one", height: 1000)
        let trailing = layout("one\n", height: 1000)
        #expect(trailing.usedHeight >= plain.usedHeight)
        #expect(!layout("one\n", height: trailing.usedHeight).isOverflowing)
    }

    @Test func singleOverlongWordWraps() {
        let word = "Supercalifragilisticexpialidocious"
        let narrow = layout(word, width: 50, height: 1000)
        let wide = layout(word, width: 1000, height: 1000)
        #expect(narrow.usedHeight > wide.usedHeight)
        #expect(layout(word, width: 50, height: wide.usedHeight).isOverflowing)
        #expect(!layout(word, width: 50, height: narrow.usedHeight).isOverflowing)
    }
}
