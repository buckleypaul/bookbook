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
        // No italic face is bundled, so italic is synthesized with a sheared font matrix.
        let italic = try #require(s.attribute(.font, at: 2, effectiveRange: nil) as? NSFont)
        #expect(italic.fontName == "AtkinsonHyperlegible-Regular")
        #expect(RichTextBridge.isSheared(italic))
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

    // MARK: Synthesized traits are drawn (TextKit 2 ignores `.obliqueness`)

    /// Pixels drawn for `text` by `TextBoxLayout` (the canvas and export path).
    private func inked(_ text: RichText) -> [Bool] {
        let size = CGSize(width: 220, height: 40)
        let ctx = LayoutFixtures.flippedBitmap(size: size, scale: 1)
        TextBoxLayout(text: text, typography: typography, containerSize: size).draw(in: ctx, origin: .zero)
        guard let data = ctx.data else { return [] }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        return (0..<(ctx.bytesPerRow * ctx.height)).map { bytes[$0] > 128 }
    }

    @Test func syntheticItalic_drawsAndRoundTripsWithBoldAndUnderline() {
        let plain = inked(RichText(plain: "Hello lll"))
        let italic = RichText(paragraphs: [Paragraph(runs: [Run(text: "Hello lll", italic: true)])])
        #expect(inked(italic) != plain)
        let all = RichText(paragraphs: [Paragraph(runs: [Run(text: "Hello lll", bold: true, italic: true, underline: true)])])
        let underlined = RichText(paragraphs: [Paragraph(runs: [Run(text: "Hello lll", underline: true)])])
        let boldUnderlined = RichText(paragraphs: [Paragraph(runs: [Run(text: "Hello lll", bold: true, underline: true)])])
        #expect(inked(all) != inked(underlined))
        #expect(inked(all) != inked(boldUnderlined))
        let s = RichTextBridge.attributedString(from: all, typography: typography)
        #expect(RichTextBridge.richText(from: s, typography: typography) == all)
    }

    @Test func syntheticBold_strokeIsDrawn() {
        // A family with no bold face gets a negative stroke width; check that TextKit 2 draws it.
        var attributes = RichTextBridge.defaultAttributes(typography: typography)
        let plain = NSAttributedString(string: "Hello lll", attributes: attributes)
        attributes[.strokeWidth] = RichTextBridge.syntheticBoldStrokeWidth
        let stroked = NSAttributedString(string: "Hello lll", attributes: attributes)
        func ink(_ s: NSAttributedString) -> Int {
            let size = CGSize(width: 220, height: 40)
            let ctx = LayoutFixtures.flippedBitmap(size: size, scale: 1)
            TextBoxLayout(attributedString: s, containerSize: size).draw(in: ctx, origin: .zero)
            guard let data = ctx.data else { return 0 }
            let bytes = data.assumingMemoryBound(to: UInt8.self)
            return (0..<(ctx.bytesPerRow * ctx.height)).filter { bytes[$0] > 128 }.count
        }
        #expect(ink(stroked) > ink(plain))
        #expect(RichTextBridge.richText(from: stroked, typography: typography).paragraphs[0].runs[0].bold)
    }

    @Test func boldBaseFace_regularFaceOfSameFamilyStaysAnOverride() throws {
        // The format bar's font menu sets a family's regular face (FontFamilies.regularFace).
        let title = avenirTitle
        let text = RichText(paragraphs: [Paragraph(runs: [
            Run(text: "The "), Run(text: "Fox", fontFamily: "AvenirNext-Regular"),
        ])])
        let s = RichTextBridge.attributedString(from: text, typography: title)
        let font = try #require(s.attribute(.font, at: 4, effectiveRange: nil) as? NSFont)
        #expect(font.fontName == "AvenirNext-Regular")
        #expect(RichTextBridge.richText(from: s, typography: title) == text)
    }
}

