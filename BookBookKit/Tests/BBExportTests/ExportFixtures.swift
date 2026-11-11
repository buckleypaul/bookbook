import AppKit
import BBLayout
import BBModel
import BBTestSupport
import CoreGraphics
import Foundation
import PDFKit
@testable import BBExport

/// Fixtures for the Phase 14 pipeline tests: a book whose pages say "LeafNN", a fake preparer
/// and a request builder that never reaches `ImagePreparationPlanner`.
@MainActor
enum ExportFixtures {
    static let imageBox = BoxID("00000000-0000-0000-0000-0000000000E1")
    static let textBox = BoxID("00000000-0000-0000-0000-0000000000E2")
    static let titleBox = BoxID("00000000-0000-0000-0000-0000000000E3")
    static let spreadText = BoxID("00000000-0000-0000-0000-0000000000E4")
    static let imageRef = ImageRef(sha256: String(repeating: "aa", count: 32), contentType: "public.png")

    static func leaf(_ n: Int) -> String { String(format: "Leaf%02d", n) }

    /// Cover ("Coverword" title) and `pages` story pages at `trim` (default 5.5×8.5 in), each
    /// with a placed image (red source) on top and its "LeafNN" text below. Pages listed in
    /// `spreads` (0-based) use a spread template whose halves say "LeafNNa" / "LeafNNb".
    static func book(pages: Int, trim: PointSize = PointSize(width: 396, height: 612),
                     bleed: Bool = false, spreads: Set<Int> = [], numbering: Bool = false) -> BookContent {
        let story = Template(name: "Image top, text below", kind: .single, boxes: [
            Box(id: imageBox, frame: NormalizedRect(x: 0.1, y: 0.08, width: 0.8, height: 0.5), content: .image),
            Box(id: textBox, frame: NormalizedRect(x: 0.1, y: 0.65, width: 0.8, height: 0.2),
                content: .text(TextBoxStyle(padding: 4))),
        ])
        let cover = Template(name: "Cover", kind: .cover, boxes: [
            Box(id: titleBox, frame: NormalizedRect(x: 0.1, y: 0.2, width: 0.8, height: 0.2),
                content: .text(TextBoxStyle()), role: .title),
        ])
        let spread = Template(name: "Spread", kind: .spread, boxes: [
            Box(id: spreadText, frame: NormalizedRect(x: 0.05, y: 0.1, width: 0.35, height: 0.3),
                content: .text(TextBoxStyle())),
            Box(id: textBox, frame: NormalizedRect(x: 0.6, y: 0.1, width: 0.35, height: 0.3),
                content: .text(TextBoxStyle())),
        ])
        var content = BookContent.makeNew(title: "Coverword", author: "", storyTemplate: story, coverTemplate: cover,
                                          storyPageCount: pages, now: Date(timeIntervalSince1970: 0))
        content.templates[spread.id] = spread
        content.style.pageSetup = PageSetup(trimSize: trim, orientation: trim.width > trim.height ? .landscape : .portrait,
                                            margins: EdgeInsetsPt(all: 18))
        content.style.pageSetup.bleedEnabled = bleed
        content.style.pageSetup.bleedAmount = 9
        content.style.typography = Typography(
            bodyFont: FontRef(postScriptName: TestFonts.Face.regular.rawValue),
            titleFont: FontRef(postScriptName: TestFonts.Face.bold.rawValue),
            bodySize: 18, color: .black, lineSpacing: 1.2, alignment: .leading)
        content.style.pageNumbers = PageNumberStyle(enabled: numbering, fontFamily: TestFonts.Face.regular.rawValue)
        for (index, pageID) in content.book.pageOrder.enumerated() {
            var page = content.pages[pageID]!
            if spreads.contains(index) {
                page.templateID = spread.id
                page.text = [spreadText: RichText(plain: leaf(index + 1) + "a"),
                             textBox: RichText(plain: leaf(index + 1) + "b")]
                content.pages[pageID] = page
                continue
            }
            if var slot = page.images[imageBox], var session = content.sessions[slot.sessionID] {
                let version = Version(image: imageRef, pixelSize: PixelSize(width: 16, height: 16), source: .imported,
                                      createdAt: Date(timeIntervalSince1970: 0))
                session.versions.append(version)
                content.sessions[session.id] = session
                slot.placement = ImagePlacement(versionID: version.id, boxAspectWhenPlaced: 1)
                page.images[imageBox] = slot
            }
            page.text[textBox] = RichText(plain: leaf(index + 1))
            content.pages[pageID] = page
        }
        return content
    }

    static func solid(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, size: Int = 16) -> CGImage {
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        return ctx.makeImage()!
    }

    /// The source images: the placed image is solid red.
    static func sourceImages() -> ImageSource { ImageSource([imageRef: solid(1, 0, 0)]) }

    /// One request per placed image box (the planner's job in the app).
    static func requests(page: Page, content: BookContent) -> [ImagePreparationRequest] {
        page.images.compactMap { boxID, slot in
            guard slot.placement != nil, let version = content.placedVersion(page: page.id, box: boxID) else { return nil }
            return ImagePreparationRequest(key: BoxImageKey(page: page.id, box: boxID), image: version.image,
                                           sourceURL: URL(fileURLWithPath: "/dev/null"),
                                           cropPixels: CGRect(x: 0, y: 0, width: 16, height: 16),
                                           requiredPixels: CGSize(width: 32, height: 32))
        }
    }

    static func exporter(_ content: BookContent, preparer: FakePreparer = FakePreparer()) -> BookExporter {
        BookExporter(content: content, images: sourceImages(), preparer: preparer,
                     requestBuilder: { page, content in requests(page: page, content: content) })
    }

    /// An exporter that prepares nothing, so every image is drawn from `images` with its
    /// placement transform (the source bitmap, not a 300 DPI preparation).
    static func sourceExporter(_ content: BookContent, images: any PageImageSource) -> BookExporter {
        BookExporter(content: content, images: images, preparer: FakePreparer(), requestBuilder: { _, _ in [] })
    }

    /// The default Standard export (cover, then every story page at trim) drawn from `images`.
    static func standardPDF(_ content: BookContent, images: any PageImageSource) async throws -> Data {
        try await sourceExporter(content, images: images).pdfData(ExportOptions()) { _ in }.0
    }

    static func document(_ data: Data) -> PDFDocument? { PDFDocument(data: data) }

    /// Each PDF page's text, whitespace-separated words.
    static func words(_ document: PDFDocument) -> [[String]] {
        (0..<document.pageCount).map {
            (document.page(at: $0)?.string ?? "").components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        }
    }

    /// Renders a PDF page (media box) to an sRGB bitmap at `scale`.
    static func bitmap(_ data: Data, page index: Int, scale: CGFloat = 1) -> CGContext? {
        guard let provider = CGDataProvider(data: data as CFData), let doc = CGPDFDocument(provider),
              let page = doc.page(at: index + 1) else { return nil }
        let box = page.getBoxRect(.mediaBox)
        guard let ctx = CGContext(data: nil, width: Int(box.width * scale), height: Int(box.height * scale),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -box.minX, y: -box.minY)
        ctx.drawPDFPage(page)
        return ctx
    }

    static func image(_ ctx: CGContext, scale: CGFloat) -> NSImage {
        NSImage(cgImage: ctx.makeImage()!, size: CGSize(width: CGFloat(ctx.width) / scale, height: CGFloat(ctx.height) / scale))
    }

    /// RGB at a point given in top-left y-down pixel coordinates.
    static func pixel(_ ctx: CGContext, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
        let i = y * ctx.bytesPerRow + x * 4
        return (data[i], data[i + 1], data[i + 2])
    }
}

/// Returns a solid green bitmap per request and records what it was asked for.
actor FakePreparer: ImagePreparing {
    private(set) var prepared: [BoxImageKey] = []
    var failure: (any Error)?

    init(failure: (any Error)? = nil) { self.failure = failure }

    func assess(_ request: ImagePreparationRequest) -> ImageAssessment {
        ImageAssessment(key: request.key, image: request.image, availablePixels: request.cropPixels.size,
                        requiredPixels: request.requiredPixels, upscaleFactor: 1, isSoft: false)
    }

    func prepare(_ request: ImagePreparationRequest) async throws -> CGImage {
        if let failure { throw failure }
        prepared.append(request.key)
        let ctx = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        return ctx.makeImage()!
    }
}
