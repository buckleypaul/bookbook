import AppKit
import BBModel
import BBTestSupport
import Testing
@testable import BBLayout

@MainActor
@Suite("RichTextBridge")
struct RichTextBridgeTests {
    let typography = LayoutFixtures.typography

    init() { LayoutFixtures.registerFonts() }

    @Test func roundTrip_runOverridesAlignmentAndParagraphs() {
        let red = RGBA(red: 0.8, green: 0.1, blue: 0.2)
        let text = RichText(paragraphs: [
            Paragraph(runs: [
                Run(text: "Once "),
                Run(text: "upon", bold: true),
                Run(text: " a ", underline: true),
                Run(text: "time", italic: true),
                Run(text: ", ", size: 30),
                Run(text: "far", bold: true, italic: true, color: red),
            ]),
            Paragraph(runs: [Run(text: "In the middle.", fontFamily: "Georgia")], alignment: .center),
            Paragraph(runs: [Run(text: "")]),
            Paragraph(runs: [Run(text: "The end", fontFamily: "No-Such-Font-Regular")], alignment: .trailing),
        ])
        let attributed = RichTextBridge.attributedString(from: text, typography: typography)
        #expect(attributed.string == "Once upon a time, far\nIn the middle.\n\nThe end")
        #expect(RichTextBridge.richText(from: attributed, typography: typography) == text)
    }

    @Test func attributes_fontsTraitsAndParagraphStyle() throws {
        let text = RichText(paragraphs: [
            Paragraph(runs: [Run(text: "a"), Run(text: "b", bold: true), Run(text: "c", italic: true)]),
            Paragraph(runs: [Run(text: "d", fontFamily: "No-Such-Font", size: 11)], alignment: .justified),
        ])
        let s = RichTextBridge.attributedString(from: text, typography: typography)
        let regular = try #require(s.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(regular.fontName == "AtkinsonHyperlegible-Regular")
        #expect(regular.pointSize == 15)
        let bold = try #require(s.attribute(.font, at: 1, effectiveRange: nil) as? NSFont)
        #expect(bold.fontName == "AtkinsonHyperlegible-Bold")
        // No italic face is bundled, so italic is synthesized.
        #expect((s.attribute(.obliqueness, at: 2, effectiveRange: nil) as? CGFloat ?? 0) > 0)
        // Missing font: system font at the requested size, no crash.
        let fallback = try #require(s.attribute(.font, at: 4, effectiveRange: nil) as? NSFont)
        #expect(fallback.pointSize == 11)
        let style = try #require(s.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        #expect(style.lineHeightMultiple == 1.2)
        #expect(style.alignment == .natural)
        let justified = try #require(s.attribute(.paragraphStyle, at: 4, effectiveRange: nil) as? NSParagraphStyle)
        #expect(justified.alignment == .justified)
    }

    @Test func inverse_mergesRunsAndDropsDefaults() {
        // Text typed in the editor with default attributes, in two attribute chunks.
        let defaults = RichTextBridge.defaultAttributes(typography: typography)
        let s = NSMutableAttributedString(string: "Hello ", attributes: defaults)
        s.append(NSAttributedString(string: "world", attributes: defaults))
        #expect(RichTextBridge.richText(from: s, typography: typography) == RichText(plain: "Hello world"))
        #expect(RichTextBridge.richText(from: NSAttributedString(), typography: typography) == .empty)
    }

    @Test func plainParagraphsRoundTrip() {
        let text = RichText(plain: "One.\nTwo.\n")
        let s = RichTextBridge.attributedString(from: text, typography: typography)
        #expect(RichTextBridge.richText(from: s, typography: typography) == text)
    }
}
