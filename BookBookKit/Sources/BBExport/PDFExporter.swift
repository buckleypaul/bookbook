import BBLayout
import BBModel
import CoreGraphics
import Foundation

/// Why a PDF export failed.
public enum PDFExportError: Error, Equatable, Sendable {
    /// The book has no story pages to export.
    case noPages
    /// Core Graphics couldn't create the PDF context.
    case contextCreationFailed
}

/// The Phase 2 synchronous Standard export: the cover, then story pages in order at trim size,
/// fonts embedded, text kept as real text. A spread-template page becomes two trim-size PDF
/// pages, its left half then its right half. Images are drawn from `images` with their
/// placement transforms (no 300 DPI preparation). Phase 14 keeps this as a thin synchronous
/// wrapper over the shared page drawing (`OutputPageDrawing`); the full pipeline, with image
/// preparation, options, print-shop and booklet output, is `BookExporter`.
@MainActor
public enum PDFExporter {
    public static func exportStandard(_ content: BookContent, images: any PageImageSource, to url: URL,
                                       pageNumbers: (PageID) -> [PageNumberMark] = { _ in [] }) throws {
        let data = try standardPDFData(content, images: images, pageNumbers: pageNumbers)
        try data.write(to: url, options: .atomic)
    }

    /// Same, into memory (tests).
    public static func standardPDFData(_ content: BookContent, images: any PageImageSource,
                                        pageNumbers: (PageID) -> [PageNumberMark] = { _ in [] }) throws -> Data {
        let story = content.storyPages
        guard !story.isEmpty else { throw PDFExportError.noPages }

        let pages = (content.coverPage.map { [$0] } ?? []) + story
        var mediaBox = PageGeometry(setup: content.style.pageSetup).trimRect
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, OutputPageDrawing.documentInfo(content))
        else { throw PDFExportError.contextCreationFailed }

        let renderer = PageRenderer(images: images)
        for page in pages {
            let marks = pageNumbers(page.id)
            let halves: [Int?] = content.template(for: page)?.kind == .spread ? [0, 1] : [nil]
            for half in halves {
                ctx.beginPDFPage(nil)
                ctx.saveGState()
                OutputPageDrawing.flipToTopLeft(ctx, height: mediaBox.height)
                OutputPageDrawing.draw(OutputSlot(page: page, half: half), content: content, renderer: renderer,
                                       marks: marks, target: .pdfTrim, bleed: 0, ctx: ctx)
                ctx.restoreGState()
                ctx.endPDFPage()
            }
        }
        ctx.closePDF()
        return data as Data
    }
}
