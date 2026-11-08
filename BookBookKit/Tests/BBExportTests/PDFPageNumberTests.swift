import BBLayout
import BBModel
import BBTestSupport
import Foundation
import PDFKit
import Testing
@testable import BBExport

/// Page numbers in the exported PDF (Phase 5 acceptance): the cover and front matter are
/// skipped, story pages carry their physical number.
@MainActor
@Suite("PDF page numbers")
struct PDFPageNumberTests {
    init() { #expect(TestFonts.registerAll()) }

    /// Cover, a dedication page, then 3 story pages; every text box empty so a page's text is
    /// only its number.
    static func book(numbering: Bool = true) -> BookContent {
        let story = Template(name: "Text", kind: .single, boxes: [
            Box(frame: NormalizedRect(x: 0.1, y: 0.1, width: 0.8, height: 0.6), content: .text(TextBoxStyle())),
        ])
        let dedication = Template(name: "Dedication", kind: .single, boxes: [
            Box(frame: NormalizedRect(x: 0.1, y: 0.3, width: 0.8, height: 0.3), content: .text(TextBoxStyle())),
        ], pageRole: .dedication)
        var content = BookContent.makeNew(title: "", storyTemplate: story,
                                          coverTemplate: Template(name: "Cover", kind: .cover, boxes: []),
                                          storyPageCount: 4, now: Date(timeIntervalSince1970: 0))
        content.templates[dedication.id] = dedication
        content.pages[content.book.pageOrder[0]]?.templateID = dedication.id
        content.style.typography.bodyFont = FontRef(postScriptName: TestFonts.Face.regular.rawValue)
        content.style.pageNumbers = PageNumberStyle(enabled: numbering, fontFamily: TestFonts.Face.regular.rawValue,
                                                    skipFrontMatter: true)
        return content
    }

    private func pageTexts(_ content: BookContent) throws -> [String] {
        let data = try PDFExporter.standardPDFData(content, images: ImageSource([:]),
                                                   pageNumbers: PageNumberMarks.make(for: content))
        let document = try #require(PDFDocument(data: data))
        return (0..<document.pageCount).map {
            (document.page(at: $0)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    @Test func numbersOnlyOnStoryPages() throws {
        let texts = try pageTexts(Self.book())
        // Cover, dedication (position 1, skipped but counted), story pages at positions 2–4.
        #expect(texts == ["", "", "2", "3", "4"])
    }

    @Test func numberingOffDrawsNothing() throws {
        #expect(try pageTexts(Self.book(numbering: false)) == ["", "", "", "", ""])
    }

    @Test func marksHelperSkipsCoverAndFrontMatter() {
        let content = Self.book()
        let marks = PageNumberMarks(content: content)
        #expect(marks.marks(for: content.book.coverPageID).isEmpty)
        #expect(marks.marks(for: content.book.pageOrder[0]).isEmpty)
        #expect(content.book.pageOrder.dropFirst().map { marks.marks(for: $0).map(\.text) } == [["2"], ["3"], ["4"]])
    }
}
