import AppKit
import BBModel
import BBTestSupport
import Testing
@testable import BBLayout

/// SplitMix64: deterministic, seedable.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@MainActor
@Suite("RichText round trip (property-based)")
struct RichTextRoundTripPropertyTests {
    let typography = LayoutFixtures.typography
    init() { LayoutFixtures.registerFonts() }

    static let words = ["fox", "a", " ", "castle ", "BOOM!", "x y", "  ", "é", "Tuesday,", "42"]
    /// Includes other faces of the style fonts' families (the test font's regular face is the
    /// title font's sibling; AvenirNext-Regular is the default title font's), which must stay
    /// overrides rather than read back as the style font.
    static let fonts: [String?] = [nil, nil, "Georgia", "Helvetica", "No-Such-Font",
                                   TestFonts.Face.regular.rawValue, "AvenirNext-Regular"]
    static let sizes: [Double?] = [nil, nil, 11, 30, 48]
    static let colors: [RGBA?] = [nil, nil, RGBA(red: 1, green: 0, blue: 0), RGBA(red: 0.2, green: 0.4, blue: 0.6)]
    static let alignments: [TextAlignment?] = [nil, nil, .center, .trailing, .justified]

    static func randomRun(_ g: inout SeededGenerator) -> Run {
        Run(text: (0..<Int.random(in: 0...3, using: &g)).map { _ in words.randomElement(using: &g)! }.joined(),
            bold: Bool.random(using: &g), italic: Bool.random(using: &g), underline: Bool.random(using: &g),
            fontFamily: fonts.randomElement(using: &g)!, size: sizes.randomElement(using: &g)!,
            color: colors.randomElement(using: &g)!)
    }

    static func randomText(_ g: inout SeededGenerator) -> RichText {
        RichText(paragraphs: (0..<Int.random(in: 1...4, using: &g)).map { _ in
            Paragraph(runs: (0..<Int.random(in: 1...4, using: &g)).map { _ in randomRun(&g) },
                      alignment: alignments.randomElement(using: &g)!)
        })
    }

    /// Drops empty runs, merges adjacent runs with equal formatting, and applies the bridge's
    /// documented limits: an empty paragraph keeps one empty run, an empty last paragraph carries
    /// no formatting, and the whole text collapses to `.empty` when it has no characters.
    /// A run naming the style font itself is the same as no override.
    static func normalised(_ text: RichText, styleFont: String) -> RichText {
        var paragraphs: [Paragraph] = []
        for (index, original) in text.paragraphs.enumerated() {
            var p = original
            for i in p.runs.indices where p.runs[i].fontFamily == styleFont { p.runs[i].fontFamily = nil }
            var runs: [Run] = []
            for run in p.runs where !run.text.isEmpty {
                if var last = runs.last, sameFormatting(last, run) {
                    last.text += run.text
                    runs[runs.count - 1] = last
                } else { runs.append(run) }
            }
            var alignment = p.alignment
            if runs.isEmpty {
                let isLast = index == text.paragraphs.count - 1
                runs = [isLast ? Run(text: "") : (p.runs.first ?? Run(text: ""))]
                if isLast { alignment = nil }
                else { runs[0].text = "" }
            }
            paragraphs.append(Paragraph(runs: runs, alignment: alignment))
        }
        if text.plainText.isEmpty && text.paragraphs.count == 1 { return .empty }
        return RichText(paragraphs: paragraphs)
    }

    static func sameFormatting(_ a: Run, _ b: Run) -> Bool {
        var x = a, y = b
        x.text = ""; y.text = ""
        return x == y
    }

    /// Body role (regular base face) and title role (bold base face, A §4.2).
    @Test(arguments: [BoxRole?.none, .title])
    func randomRunsRoundTrip(role: BoxRole?) {
        let typography = typography.resolved(for: role)
        var generator = SeededGenerator(seed: 0xB00C_B00C)
        var failures: [String] = []
        for caseIndex in 0..<300 {
            let text = Self.randomText(&generator)
            let attributed = RichTextBridge.attributedString(from: text, typography: typography)
            let back = RichTextBridge.richText(from: attributed, typography: typography)
            let expected = Self.normalised(text, styleFont: typography.bodyFont.postScriptName)
            if back != expected, failures.count < 3 { failures.append("case \(caseIndex): \(text)\n -> \(back)\n != \(expected)") }
            #expect(attributed.string == text.plainText)
        }
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
    }

    @Test func runsWithoutOverridesFollowTypographyChanges() throws {
        let text = RichText(paragraphs: [Paragraph(runs: [
            Run(text: "plain "), Run(text: "BOOM!", fontFamily: "Georgia", size: 48, color: RGBA(red: 1, green: 0, blue: 0)),
        ])])
        var changed = typography
        changed.bodyFont = FontRef(postScriptName: "Helvetica")
        changed.bodySize = 22
        changed.alignment = .center
        let s = RichTextBridge.attributedString(from: text, typography: changed)
        let plain = try #require(s.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(plain.fontName == "Helvetica" && plain.pointSize == 22)
        let boom = try #require(s.attribute(.font, at: 7, effectiveRange: nil) as? NSFont)
        #expect(boom.fontName.hasPrefix("Georgia") && boom.pointSize == 48)
        let style = try #require(s.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        #expect(style.alignment == .center)
        // And converting back against the new typography keeps the overrides, not the defaults.
        #expect(RichTextBridge.richText(from: s, typography: changed) == text)
    }

    @Test func titleRunsWithoutOverridesFollowTitleFontChanges() throws {
        let text = RichText(paragraphs: [Paragraph(runs: [Run(text: "plain "), Run(text: "light", bold: true)])])
        var style = typography
        let boldTitle = RichTextBridge.attributedString(from: text, typography: style.resolved(for: .title))
        let drawnBold = try #require(boldTitle.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(drawnBold.fontName == TestFonts.Face.bold.rawValue)
        let toggled = try #require(boldTitle.attribute(.font, at: 6, effectiveRange: nil) as? NSFont)
        #expect(toggled.fontName == TestFonts.Face.regular.rawValue)
        #expect(RichTextBridge.richText(from: boldTitle, typography: style.resolved(for: .title)) == text)

        style.titleFont = FontRef(postScriptName: TestFonts.Face.regular.rawValue)
        let regularTitle = RichTextBridge.attributedString(from: text, typography: style.resolved(for: .title))
        let plain = try #require(regularTitle.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(plain.fontName == TestFonts.Face.regular.rawValue)
        let bold = try #require(regularTitle.attribute(.font, at: 6, effectiveRange: nil) as? NSFont)
        #expect(bold.fontName == TestFonts.Face.bold.rawValue)
    }
}
