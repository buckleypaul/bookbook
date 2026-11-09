import AppKit
import BBModel
import Foundation
import Testing
@testable import BBLayout

@MainActor
@Suite struct Phase16bTextImportTests {
    private func write(_ data: Data, ext: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("story-\(UUID().uuidString).\(ext)")
        try data.write(to: url)
        return url
    }

    /// #71a: `.text`, `.md` and `.markdown` read as plain text (case-insensitive).
    @Test(arguments: ["text", "md", "markdown", "MD", "txt"])
    func plainTextExtensionsRead(ext: String) throws {
        let url = try write(Data("# One\r\n\r\nTwo".utf8), ext: ext)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try StoryTextImporter.read(url, typography: .default).plainText == "# One\n\nTwo")
    }

    /// #71a: `.rtfd` is still unsupported (v1.x).
    @Test func rtfdUnsupported() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("a.rtfd")
        #expect(throws: StoryImportError.unsupportedType) {
            try StoryTextImporter.read(url, typography: .default)
        }
    }

    /// #71c: RTF in its own font and size takes the body font; bold, italic, underline and
    /// alignment are kept.
    @Test func rtfDropsFontFamilyAndSizeKeepsStyle() throws {
        let source = NSMutableAttributedString(string: "Light bold italic under\ncentred")
        let all = NSRange(location: 0, length: source.length)
        let light = NSFont(name: "Helvetica-Light", size: 31) ?? NSFont.systemFont(ofSize: 31, weight: .light)
        source.addAttribute(.font, value: light, range: all)
        let helvetica = NSFont(name: "Helvetica", size: 31) ?? NSFont.systemFont(ofSize: 31)
        let bold = NSFontManager.shared.convert(helvetica, toHaveTrait: .boldFontMask)
        let italic = NSFontManager.shared.convert(helvetica, toHaveTrait: .italicFontMask)
        source.addAttribute(.font, value: bold, range: NSRange(location: 6, length: 4))
        source.addAttribute(.font, value: italic, range: NSRange(location: 11, length: 6))
        source.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: NSRange(location: 18, length: 5))
        let centred = NSMutableParagraphStyle()
        centred.alignment = .center
        source.addAttribute(.paragraphStyle, value: centred, range: NSRange(location: 24, length: 7))
        let data = try source.data(from: all, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let url = try write(data, ext: "rtf")
        defer { try? FileManager.default.removeItem(at: url) }

        let rich = try StoryTextImporter.read(url, typography: .default)
        let runs = rich.paragraphs.flatMap(\.runs)
        #expect(runs.allSatisfy { $0.fontFamily == nil && $0.size == nil })
        #expect(runs.contains { $0.bold && !$0.italic && $0.text == "bold" })
        #expect(runs.contains { $0.italic && !$0.bold && $0.text == "italic" })
        #expect(runs.contains { $0.underline && $0.text == "under" })
        #expect(runs.contains { !$0.bold && !$0.italic && !$0.underline && $0.text.hasPrefix("Light") })
        #expect(rich.paragraphs[1].alignment == .center)
        // Runs that differed only by font merge once the font is dropped.
        #expect(rich.paragraphs[1].runs.count == 1)
    }

    /// #71c: bold/italic flags are re-expressed relative to the body face (A §4.2).
    @Test func flagsAreRelativeToBodyFace() {
        var typography = Typography.default
        typography.bodyFont = FontRef(postScriptName: "Helvetica-Bold")
        let text = RichText(paragraphs: [Paragraph(runs: [
            Run(text: "plain", fontFamily: "Helvetica"),
            Run(text: "bold", bold: true, fontFamily: "Helvetica"),
        ])])
        let result = StoryTextImporter.usingBodyFont(text, typography: typography)
        // On a bold body face, drawn-plain text is `bold: true` and drawn-bold text is `bold: false`.
        #expect(result.paragraphs[0].runs == [Run(text: "plain", bold: true), Run(text: "bold")])
    }

    /// #80b: bitmap-only embedding (bit 9) isn't embeddable.
    @Test func bitmapOnlyEmbeddingNotAllowed() {
        #expect(!FontInspector.embeddingAllowed(fsType: 0x0200))
        #expect(!FontInspector.embeddingAllowed(fsType: 0x0204))   // preview & print, bitmap only
        #expect(!FontInspector.embeddingAllowed(fsType: 0x0208))   // editable, bitmap only
        #expect(FontInspector.embeddingAllowed(fsType: 0x0108))    // editable, no subsetting
        #expect(FontInspector.embeddingAllowed(fsType: 0x0000))
    }
}
