import BBLayout
import BBModel
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The export pipeline (A §9.1, §9.3, PD §8.8): book snapshot → `PageSequencer` → imposition
/// (standard, print shop or booklet) → `ImagePreparing` per page → `PageRenderer` into a
/// `CGPDFContext` (or a 300 DPI bitmap).
///
/// Drawing stays on the main actor (TextKit 2): one output unit (PDF page or booklet sheet side)
/// per step, with a yield in between so the UI stays live. Images for a unit are prepared by
/// the preparer (off the main actor), drawn, then released before the next unit.
@MainActor
public final class BookExporter {
    /// Builds one page's image-preparation requests. The default is `ImagePreparationPlanner`.
    typealias RequestBuilder = @MainActor (Page, BookContent) -> [ImagePreparationRequest]

    /// Bitmap export resolution (A §9.1).
    static let bitmapDPI: CGFloat = PrintResolution.dpi
    static let jpegQuality: CGFloat = 0.92

    let content: BookContent
    let images: any PageImageSource
    let preparer: any ImagePreparing
    let requestBuilder: RequestBuilder

    public convenience init(content: BookContent, images: any PageImageSource, preparer: any ImagePreparing,
                            imageURL: @escaping @Sendable (ImageRef) -> URL) {
        self.init(content: content, images: images, preparer: preparer, requestBuilder: { page, content in
            ImagePreparationPlanner.requests(page: page, in: content, imageURL: imageURL,
                                             pixelSize: { ImagePixelSize.of(url: imageURL($0)) })
        })
    }

    /// Test seam: inject the request builder so tests never reach the planner.
    init(content: BookContent, images: any PageImageSource, preparer: any ImagePreparing,
         requestBuilder: @escaping RequestBuilder) {
        self.content = content
        self.images = images
        self.preparer = preparer
        self.requestBuilder = requestBuilder
    }

    // MARK: Public API

    public func pdfData(_ options: ExportOptions,
                        progress: @MainActor (ExportProgress) -> Void) async throws -> (Data, ExportResult) {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { throw ExportError.contextCreationFailed }
        let result = try await render(options, into: consumer, progress: progress)
        return (data as Data, result)
    }

    /// Writes to a temporary file next to `url`, then moves it into place, so a cancelled or
    /// failed export never leaves a partial file at `url`.
    public func export(_ options: ExportOptions, to url: URL,
                       progress: @MainActor (ExportProgress) -> Void) async throws -> ExportResult {
        let fm = FileManager.default
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        defer { try? fm.removeItem(at: temp) }
        guard let consumer = CGDataConsumer(url: temp as CFURL) else { throw ExportError.contextCreationFailed }
        let result = try await render(options, into: consumer, progress: progress)
        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: temp)
        } else {
            try fm.moveItem(at: temp, to: url)
        }
        return result
    }

    /// One page (a spread: both halves, double width) at 300 DPI, trim size, no bleed.
    public func bitmapData(page pageID: PageID, format: BitmapFormat) async throws -> Data {
        guard let page = content.pages[pageID] else { throw ExportError.noPages }
        let slot = OutputSlot(page: page, half: nil)
        let prepared = try await prepareImages(for: [page])
        try Task.checkCancellation()

        let size = OutputPageDrawing.trimSize(of: slot, in: content)
        let scale = Self.bitmapDPI / 72
        let width = Int((size.width * scale).rounded())
        let height = Int((size.height * scale).rounded())
        let alpha: CGImageAlphaInfo = format == .png ? .premultipliedLast : .noneSkipLast
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: alpha.rawValue)
        else { throw ExportError.contextCreationFailed }
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: scale, y: -scale)
        var renderer = PageRenderer(images: images)
        renderer.prepared = prepared
        OutputPageDrawing.draw(slot, content: content, renderer: renderer,
                               marks: PageNumberMarks.make(for: content)(page.id), target: .pdfTrim, bleed: 0, ctx: ctx)
        guard let image = ctx.makeImage() else { throw ExportError.encodingFailed }
        return try Self.encode(image, format: format)
    }

    /// Cover only, single trim-size page: for printing on card when a booklet excludes it.
    public func coverPDFData() async throws -> Data {
        guard let cover = content.coverPage else { throw ExportError.noPages }
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { throw ExportError.contextCreationFailed }
        _ = try await renderPages([OutputSlot(page: cover, half: nil)], kind: .standard, into: consumer,
                                  progress: { _ in })
        return data as Data
    }

    // MARK: Sequencing

    /// Story pages in reading order with their positions (A §8.1), filtered by `range` (a range
    /// that cuts a spread widens to the whole spread). The one page selection that export,
    /// preflight and the export sheet all use.
    public nonisolated static func storyPositions(_ content: BookContent,
                                                  range: ClosedRange<Int>?) -> [(page: Page, position: PagePosition)] {
        let story = content.storyPages
        let layout = PageSequencer.layout(for: content)
        let pairs = Array(zip(story, layout.pages))
        let selected = PageRangeWidening.selected(pairs.map { (position: $0.1.position, span: $0.1.span) }, in: range)
        let keep = Set(selected.map(\.position))
        return pairs.filter { keep.contains($0.1.position) }.map { (page: $0.0, position: $0.1) }
    }

    /// Output pages for standard and print-shop exports.
    func pageSlots(_ options: ExportOptions) -> [OutputSlot] {
        var slots: [OutputSlot] = []
        if options.includeCover, let cover = content.coverPage { slots.append(OutputSlot(page: cover, half: nil)) }
        let pages = Self.storyPositions(content, range: options.pageRange).map(\.page)
        return slots + storySlots(pages, splitSpreads: options.spreads == .singlePages)
    }

    /// One slot per page, or two halves for a spread page when `splitSpreads`.
    private func storySlots(_ pages: [Page], splitSpreads: Bool) -> [OutputSlot] {
        pages.flatMap { page -> [OutputSlot] in
            if splitSpreads, content.template(for: page)?.kind == .spread {
                return [OutputSlot(page: page, half: 0), OutputSlot(page: page, half: 1)]
            }
            return [OutputSlot(page: page, half: nil)]
        }
    }

    /// Booklet pages in folded reading order, padded (A §9.3): cover first when included,
    /// spreads always as halves, a leading blank when needed so each story page keeps the side
    /// `PageSequencer` gives it (so spreads face each other and outer page numbers stay
    /// outside), and trailing blanks to a multiple of 4. Blank slots have no page.
    func bookletPages(_ options: ExportOptions) -> [OutputSlot] {
        var head: [OutputSlot] = []
        if options.includeCover, let cover = content.coverPage { head.append(OutputSlot(page: cover, half: nil)) }
        let positions = Self.storyPositions(content, range: options.pageRange)
        let story = storySlots(positions.map(\.page), splitSpreads: true)
        guard !head.isEmpty || !story.isEmpty else { return [] }
        let blanks = BookletImposition.blanks(contentPages: head.count + story.count, includeCover: !head.isEmpty,
                                              firstStoryPosition: positions.first?.position.position)
        return head + Array(repeating: .blank, count: blanks.leading) + story
            + Array(repeating: .blank, count: blanks.trailing)
    }

    // MARK: Rendering

    private func render(_ options: ExportOptions, into consumer: CGDataConsumer,
                        progress: @MainActor (ExportProgress) -> Void) async throws -> ExportResult {
        switch options.kind {
        case .standard:
            return try await renderPages(pageSlots(options), kind: .standard, into: consumer, progress: progress)
        case .printShop:
            guard content.style.pageSetup.bleedEnabled else { throw ExportError.bleedRequired }
            return try await renderPages(pageSlots(options), kind: .printShop, into: consumer, progress: progress)
        case .booklet(let sheet):
            return try await renderBooklet(bookletPages(options), sheet: sheet, into: consumer, progress: progress)
        }
    }

    /// One PDF page per slot. Standard: media = trim. Print shop: media = trim + bleed + mark
    /// area on each side, with TrimBox/BleedBox and crop marks.
    private func renderPages(_ slots: [OutputSlot], kind: ExportKind, into consumer: CGDataConsumer,
                             progress: @MainActor (ExportProgress) -> Void) async throws -> ExportResult {
        guard !slots.isEmpty else { throw ExportError.noPages }
        let isPrintShop = kind == .printShop
        let bleed = isPrintShop ? PageGeometry(setup: content.style.pageSetup).bleed : 0
        let margin = isPrintShop ? bleed + CropMarks.markArea : 0
        let firstTrim = OutputPageDrawing.trimSize(of: slots[0], in: content)
        var defaultMedia = CGRect(x: 0, y: 0, width: firstTrim.width + 2 * margin, height: firstTrim.height + 2 * margin)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &defaultMedia, OutputPageDrawing.documentInfo(content))
        else { throw ExportError.contextCreationFailed }

        let marks = PageNumberMarks.make(for: content)
        let total = slots.count
        for (index, slot) in slots.enumerated() {
            try Task.checkCancellation()
            let prepared = try await prepareImages(for: slot.page.map { [$0] } ?? [])
            try Task.checkCancellation()

            let trim = OutputPageDrawing.trimSize(of: slot, in: content)
            let media = CGRect(x: 0, y: 0, width: trim.width + 2 * margin, height: trim.height + 2 * margin)
            let trimPDF = CGRect(x: margin, y: margin, width: trim.width, height: trim.height)
            var info: [CFString: Any] = [kCGPDFContextMediaBox: OutputPageDrawing.boxValue(media)]
            if isPrintShop {
                info[kCGPDFContextTrimBox] = OutputPageDrawing.boxValue(trimPDF)
                info[kCGPDFContextBleedBox] = OutputPageDrawing.boxValue(trimPDF.insetBy(dx: -bleed, dy: -bleed))
            }
            ctx.beginPDFPage(info as CFDictionary)
            ctx.saveGState()
            OutputPageDrawing.flipToTopLeft(ctx, height: media.height)
            if isPrintShop {
                drawCropMarks(trim: CGRect(x: margin, y: margin, width: trim.width, height: trim.height),
                              bleed: bleed, ctx: ctx)
            }
            ctx.translateBy(x: margin, y: margin)
            var renderer = PageRenderer(images: images)
            renderer.prepared = prepared
            OutputPageDrawing.draw(slot, content: content, renderer: renderer,
                                   marks: slot.page.map { marks($0.id) } ?? [],
                                   target: isPrintShop ? .pdfBleed : .pdfTrim, bleed: bleed, ctx: ctx)
            ctx.restoreGState()
            ctx.endPDFPage()

            progress(ExportProgress(completedUnits: index + 1, totalUnits: total))
            await Task.yield()
        }
        ctx.closePDF()
        return ExportResult(pageCount: total)
    }

    /// Booklet: `pages` already padded by `bookletPages`; one PDF page per sheet side (A §9.3).
    private func renderBooklet(_ pages: [OutputSlot], sheet: SheetSize, into consumer: CGDataConsumer,
                               progress: @MainActor (ExportProgress) -> Void) async throws -> ExportResult {
        guard !pages.isEmpty else { throw ExportError.noPages }
        let padded = pages.count
        let blanks = pages.filter { $0.page == nil }.count
        let all = pages
        let pageSize = PageGeometry(setup: content.style.pageSetup).trimSize
        let layout = BookletImposition.layout(pageSize: pageSize, sheet: sheet)
        let sides = BookletImposition.sheetSides(pageCount: padded)

        var media = CGRect(origin: .zero, size: layout.sheetSize)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &media, OutputPageDrawing.documentInfo(content))
        else { throw ExportError.contextCreationFailed }

        let marks = PageNumberMarks.make(for: content)
        for (index, side) in sides.enumerated() {
            try Task.checkCancellation()
            let placed = [(all[side.leftPage - 1], layout.firstSlot), (all[side.rightPage - 1], layout.secondSlot)]
            let prepared = try await prepareImages(for: placed.compactMap(\.0.page))
            try Task.checkCancellation()

            ctx.beginPDFPage([kCGPDFContextMediaBox: OutputPageDrawing.boxValue(media)] as CFDictionary)
            ctx.saveGState()
            OutputPageDrawing.flipToTopLeft(ctx, height: media.height)
            OutputPageDrawing.drawBlank(size: media.size, ctx: ctx)
            var renderer = PageRenderer(images: images)
            renderer.prepared = prepared
            for (slot, slotRect) in placed {
                let rect = BookletLayoutEngine.pageRect(in: slotRect, pageSize: pageSize, scale: layout.scale)
                ctx.saveGState()
                ctx.translateBy(x: rect.minX, y: rect.minY)
                ctx.scaleBy(x: layout.scale, y: layout.scale)
                OutputPageDrawing.draw(slot, content: content, renderer: renderer,
                                       marks: slot.page.map { marks($0.id) } ?? [],
                                       target: .pdfTrim, bleed: 0, ctx: ctx)
                ctx.restoreGState()
            }
            ctx.restoreGState()
            ctx.endPDFPage()

            progress(ExportProgress(completedUnits: index + 1, totalUnits: sides.count))
            await Task.yield()
        }
        ctx.closePDF()
        return ExportResult(pageCount: sides.count, blanksAdded: blanks, scaledToFit: layout.scaledToFit,
                            scale: layout.scale, printingInstructions: layout.printingInstructions)
    }

    /// Crop marks in media space (y down), black hairlines.
    private func drawCropMarks(trim: CGRect, bleed: CGFloat, ctx: CGContext) {
        ctx.saveGState()
        // "Registration" colour: 100 percent of every CMYK ink. A true Separation "All" colour
        // can't be made through CGColor, so this is the closest a CGContext offers.
        let cmyk = CGColorSpace(name: CGColorSpace.genericCMYK)
        let registration = cmyk.flatMap { CGColor(colorSpace: $0, components: [1, 1, 1, 1, 1]) }
        ctx.setStrokeColor(registration ?? CGColor(gray: 0, alpha: 1))
        ctx.setLineWidth(CropMarks.lineWidth)
        for segment in CropMarks.segments(trim: trim, bleed: bleed) {
            ctx.move(to: segment.start)
            ctx.addLine(to: segment.end)
        }
        ctx.strokePath()
        ctx.restoreGState()
    }

    // MARK: Images

    /// Prepares every placed image on `pages` (deduplicated by page). The result is dropped by
    /// the caller after the unit is drawn, so at most one unit's bitmaps are held at a time.
    private func prepareImages(for pages: [Page]) async throws -> PreparedImages {
        var result: [BoxImageKey: CGImage] = [:]
        var seen: Set<PageID> = []
        for page in pages where seen.insert(page.id).inserted {
            for request in requestBuilder(page, content) {
                try Task.checkCancellation()
                do {
                    result[request.key] = try await preparer.prepare(request)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw ExportError.imageUnreadable(request.image)
                }
            }
        }
        return PreparedImages(result)
    }

    // MARK: Encoding

    static func encode(_ image: CGImage, format: BitmapFormat) throws -> Data {
        let data = NSMutableData()
        let type = format == .png ? UTType.png : UTType.jpeg
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, type.identifier as CFString, 1, nil)
        else { throw ExportError.encodingFailed }
        var properties: [CFString: Any] = [
            kCGImagePropertyDPIWidth: bitmapDPI, kCGImagePropertyDPIHeight: bitmapDPI,
        ]
        if format == .jpeg { properties[kCGImageDestinationLossyCompressionQuality] = jpegQuality }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ExportError.encodingFailed }
        return data as Data
    }
}

/// One unit's prepared bitmaps, keyed by box.
@MainActor
final class PreparedImages: PreparedImageSource {
    private let images: [BoxImageKey: CGImage]
    init(_ images: [BoxImageKey: CGImage]) { self.images = images }
    func preparedImage(for key: BoxImageKey) -> CGImage? { images[key] }
}
