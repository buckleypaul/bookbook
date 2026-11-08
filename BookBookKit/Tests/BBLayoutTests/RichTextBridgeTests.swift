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

    // MARK: Bold base face (title role)

    /// The default title font is a bold face; flags are relative to it (A §4.2).
    var avenirTitle: Typography {
        var t = Typography.default.resolved(for: .title)
        t.bodySize = 15
        return t
    }

    @Test func boldBaseFace_unformattedRunReadsBackNotBold() throws {
        let title = avenirTitle
        #expect(title.bodyFont.postScriptName == "AvenirNext-Bold")
        let text = RichText(plain: "The Fox")
        let s = RichTextBridge.attributedString(from: text, typography: title)
        let font = try #require(s.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(font.fontName == "AvenirNext-Bold")
        let back = RichTextBridge.richText(from: s, typography: title)
        #expect(back == text)
        #expect(back.paragraphs[0].runs.allSatisfy { !$0.bold && !$0.italic && $0.fontFamily == nil })
        // Text typed into an empty title editor reads back unformatted too.
        let typed = NSAttributedString(string: "Hi", attributes: RichTextBridge.defaultAttributes(typography: title))
        #expect(RichTextBridge.richText(from: typed, typography: title) == RichText(plain: "Hi"))
    }

    @Test func boldBaseFace_boldFlagDrawsRegularAndRoundTrips() throws {
        let title = avenirTitle
        let text = RichText(paragraphs: [Paragraph(runs: [
            Run(text: "The "), Run(text: "Fox", bold: true), Run(text: "!", italic: true),
        ])])
        let s = RichTextBridge.attributedString(from: text, typography: title)
        let toggled = try #require(s.attribute(.font, at: 4, effectiveRange: nil) as? NSFont)
        #expect(!toggled.fontDescriptor.symbolicTraits.contains(.bold))
        #expect(toggled.familyName == "Avenir Next")
        #expect(RichTextBridge.richText(from: s, typography: title) == text)
        // An editor un-bolding a run (NSFontManager on the drawn font) reads back as the toggle.
        let edited = NSMutableAttributedString(attributedString: RichTextBridge.attributedString(
            from: RichText(plain: "The Fox"), typography: title))
        let drawn = try #require(edited.attribute(.font, at: 4, effectiveRange: nil) as? NSFont)
        edited.addAttribute(.font, value: NSFontManager.shared.convert(drawn, toNotHaveTrait: .boldFontMask),
                            range: NSRange(location: 4, length: 3))
        #expect(RichTextBridge.richText(from: edited, typography: title)
            == RichText(paragraphs: [Paragraph(runs: [Run(text: "The "), Run(text: "Fox", bold: true)])]))
    }

    @Test func boldBaseFace_changingTitleFontToRegularDrawsRegular() throws {
        var style = Typography.default
        style.bodySize = 15
        let text = RichTextBridge.richText(
            from: RichTextBridge.attributedString(from: RichText(plain: "The Fox"), typography: style.resolved(for: .title)),
            typography: style.resolved(for: .title))
        style.titleFont = FontRef(postScriptName: "AvenirNext-Regular")
        let s = RichTextBridge.attributedString(from: text, typography: style.resolved(for: .title))
        let font = try #require(s.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(font.fontName == "AvenirNext-Regular")
        #expect(!font.fontDescriptor.symbolicTraits.contains(.bold))
        #expect(s.attribute(.strokeWidth, at: 0, effectiveRange: nil) == nil)
    }
}
