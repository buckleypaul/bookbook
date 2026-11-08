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

/// File ▸ Export PDF… (Standard) for the slice: the cover, then story pages in order at trim size, fonts
/// embedded, text kept as real text (A §9.1, thin). The cover is the first page.
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
        let geometry = PageGeometry(setup: content.style.pageSetup)
        var mediaBox = geometry.trimRect
        let data = NSMutableData()
        var info: [CFString: Any] = [kCGPDFContextCreator: "BookBook"]
        if !content.book.title.isEmpty { info[kCGPDFContextTitle] = content.book.title }
        if !content.book.author.isEmpty { info[kCGPDFContextAuthor] = content.book.author }
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, info as CFDictionary)
        else { throw PDFExportError.contextCreationFailed }

        let renderer = PageRenderer(images: images)
        for page in pages {
            ctx.beginPDFPage(nil)
            ctx.saveGState()
            // PageRenderer draws in trim space with a top-left origin, y down.
            ctx.translateBy(x: 0, y: mediaBox.height)
            ctx.scaleBy(x: 1, y: -1)
            renderer.draw(page: page, in: content, into: ctx, options: RenderOptions(target: .pdfTrim, pageNumbers: pageNumbers(page.id)))
            ctx.restoreGState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return data as Data
    }
}
