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
/// embedded, text kept as real text (A §9.1, thin). The cover is the first page. A spread-template
/// page becomes two trim-size PDF pages, its left half then its right half.
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
            let marks = pageNumbers(page.id)
            guard content.template(for: page)?.kind == .spread else {
                ctx.beginPDFPage(nil)
                ctx.saveGState()
                // PageRenderer draws in trim space with a top-left origin, y down.
                ctx.translateBy(x: 0, y: mediaBox.height)
                ctx.scaleBy(x: 1, y: -1)
                renderer.draw(page: page, in: content, into: ctx, options: RenderOptions(target: .pdfTrim, pageNumbers: marks))
                ctx.restoreGState()
                ctx.endPDFPage()
                continue
            }
            // A spread exports as two single pages (PD §9 default): the spread is drawn at double
            // width, as on the canvas, shifted and clipped to one half per PDF page. Each half
            // gets only its own page-number mark.
            let spreadContent = PageGeometry.drawContent(for: page, in: content)
            for half in 0..<2 {
                let halfRect = CGRect(x: CGFloat(half) * mediaBox.width, y: 0,
                                      width: mediaBox.width, height: mediaBox.height)
                ctx.beginPDFPage(nil)
                ctx.saveGState()
                ctx.translateBy(x: 0, y: mediaBox.height)
                ctx.scaleBy(x: 1, y: -1)
                ctx.translateBy(x: -halfRect.minX, y: 0)
                ctx.clip(to: halfRect)
                let options = RenderOptions(target: .pdfTrim, pageNumbers: marks.filter { $0.half == half })
                renderer.draw(page: page, in: spreadContent, into: ctx, options: options, visibleRect: halfRect)
                ctx.restoreGState()
                ctx.endPDFPage()
            }
        }
        ctx.closePDF()
        return data as Data
    }
}
