import AppKit
import BBModel
import Foundation
import Testing
@testable import BBLayout

@MainActor
@Suite struct StoryTextImporterTests {
    private func pages(_ s: String, _ rule: StorySplitRule) -> [String] {
        StoryTextImporter.split(StoryTextImporter.richText(fromPlain: s), rule: rule).map(\.plainText)
    }

    @Test func blankLinesIncludingMultipleAndWhitespaceOnly() {
        let s = "One\nstill one\n\n\n  \t \nTwo\n\nThree\n"
        #expect(pages(s, .blankLines) == ["One\nstill one", "Two", "Three"])
    }

    @Test func markerSplitKeepsInnerBlankLinesAndTrimsEnds() {
        let s = "\nA1\n\nA2\n\n---\n  ---  \n\nB\n---\n"
        #expect(pages(s, .marker("---")) == ["A1\n\nA2", "B"])
    }

    @Test func crlfAndCRNormalised() {
        #expect(pages("A\r\n\r\nB\rC\r\n\r\nD", .blankLines) == ["A", "B\nC", "D"])
        #expect(StoryTextImporter.richText(fromPlain: "x\r\ny\rz").plainText == "x\ny\nz")
    }

    @Test func twelveParagraphsWithMarkers() {
        let s = (1...12).map { "Page \($0)\n\nmore" }.joined(separator: "\n---\n")
        let result = pages(s, .marker("---"))
        #expect(result.count == 12)
        #expect(result[11] == "Page 12\n\nmore")
    }

    @Test func emptyPagesDropped() {
        #expect(pages("---\n---\nA\n---\n   \n---\n", .marker("---")) == ["A"])
        #expect(pages("", .blankLines).isEmpty)
        #expect(pages("\n\n\n", .blankLines).isEmpty)
    }

    @Test func formattingSurvivesSplit() {
        let bold = Run(text: "Bold", bold: true)
        let italic = Run(text: "Italic", italic: true)
        let text = RichText(paragraphs: [
            Paragraph(runs: [bold, Run(text: " plain")]),
            Paragraph(runs: [Run(text: "")]),
            Paragraph(runs: [italic]),
        ])
        let result = StoryTextImporter.split(text, rule: .blankLines)
        #expect(result.count == 2)
        #expect(result[0].paragraphs[0].runs == [bold, Run(text: " plain")])
        #expect(result[1].paragraphs[0].runs == [italic])
    }

    @Test func readRTFKeepsBoldAndItalic() throws {
        let source = NSMutableAttributedString(string: "Hello bold and italic\r\n\r\nSecond")
        let font = NSFont.systemFont(ofSize: 14)
        source.addAttribute(.font, value: font, range: NSRange(location: 0, length: source.length))
        let boldFont = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        let italicFont = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        source.addAttribute(.font, value: boldFont, range: NSRange(location: 6, length: 4))
        source.addAttribute(.font, value: italicFont, range: NSRange(location: 15, length: 6))
        let data = try source.data(from: NSRange(location: 0, length: source.length),
                                   documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("story-\(UUID().uuidString).rtf")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let rich = try StoryTextImporter.read(url, typography: .default)
        #expect(rich.plainText.contains("\r") == false)
        let runs = rich.paragraphs.flatMap(\.runs)
        #expect(runs.contains { $0.bold && $0.text == "bold" })
        #expect(runs.contains { $0.italic && $0.text == "italic" })
        #expect(StoryTextImporter.split(rich, rule: .blankLines).count == 2)
    }

    @Test func readTextFileAndFallbackEncoding() throws {
        let dir = FileManager.default.temporaryDirectory
        let utf8 = dir.appendingPathComponent("story-\(UUID().uuidString).txt")
        try Data("Caf\u{E9}\r\nTwo".utf8).write(to: utf8)
        let latin = dir.appendingPathComponent("story-\(UUID().uuidString).TXT")
        try Data([0x43, 0x61, 0x66, 0xE9]).write(to: latin)
        defer { try? FileManager.default.removeItem(at: utf8); try? FileManager.default.removeItem(at: latin) }

        #expect(try StoryTextImporter.read(utf8, typography: .default).plainText == "Caf\u{E9}\nTwo")
        #expect(try StoryTextImporter.read(latin, typography: .default).plainText.hasPrefix("Caf"))
    }

    @Test func unsupportedAndUnreadable() {
        let dir = FileManager.default.temporaryDirectory
        #expect(throws: StoryImportError.unsupportedType) {
            try StoryTextImporter.read(dir.appendingPathComponent("a.docx"), typography: .default)
        }
        #expect(throws: StoryImportError.unreadable) {
            try StoryTextImporter.read(dir.appendingPathComponent("missing-\(UUID().uuidString).txt"), typography: .default)
        }
        #expect(throws: StoryImportError.unreadable) {
            try StoryTextImporter.read(dir.appendingPathComponent("missing-\(UUID().uuidString).rtf"), typography: .default)
        }
    }
}
