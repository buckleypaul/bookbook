import BBLayout
import BBModel
import BBTestSupport
import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import BBExport

@MainActor
@Suite("PDFExporter")
struct PDFExporterTests {
    init() { #expect(TestFonts.registerAll()) }

    static let imageBoxID = BoxID("00000000-0000-0000-0000-0000000000C1")
    static let textBoxID = BoxID("00000000-0000-0000-0000-0000000000C2")
    static let imageRef = ImageRef(sha256: String(repeating: "cd", count: 32), contentType: "public.png")
    static let pageTexts = [
        "The fox wore a red scarf to the castle gate.",
        "Nobody had told her the castle was closed on Tuesdays.",
    ]

    /// A two-story-page Letter book: image on top, text below, a solid image placed on each page.
    static func book() -> BookContent {
        let template = Template(name: "Image top, text below", kind: .single, boxes: [
            Box(id: imageBoxID, frame: NormalizedRect(x: 0.06, y: 0.05, width: 0.88, height: 0.6), content: .image),
            Box(id: textBoxID, frame: NormalizedRect(x: 0.06, y: 0.7, width: 0.88, height: 0.24),
                content: .text(TextBoxStyle(padding: 8))),
        ])
        var content = BookContent.makeNew(title: "The Fox Book", author: "A. Tester", storyTemplate: template,
                                          coverTemplate: Template(name: "Cover", kind: .cover, boxes: []), storyPageCount: 2, now: Date(timeIntervalSince1970: 0))
        content.style.typography = Typography(
            bodyFont: FontRef(postScriptName: TestFonts.Face.regular.rawValue),
            titleFont: FontRef(postScriptName: TestFonts.Face.bold.rawValue),
            bodySize: 20, color: .black, lineSpacing: 1.2, alignment: .leading)
        for (index, pageID) in content.book.pageOrder.enumerated() {
            var page = content.pages[pageID]!
            var slot = page.images[imageBoxID]!
            var session = content.sessions[slot.sessionID]!
            let version = Version(image: imageRef, pixelSize: PixelSize(width: 16, height: 16), source: .imported,
                                  createdAt: Date(timeIntervalSince1970: 0))
            session.versions.append(version)
            content.sessions[session.id] = session
            slot.placement = ImagePlacement(versionID: version.id, boxAspectWhenPlaced: 1)
            page.images[imageBoxID] = slot
            page.text[textBoxID] = RichText(paragraphs: [Paragraph(runs: [
                Run(text: "Page \(index + 1). ", bold: true), Run(text: pageTexts[index]),
            ])])
            content.pages[pageID] = page
        }
        return content
    }

    static func images() -> ImageSource {
        let ctx = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0.9, green: 0.4, blue: 0.1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        return ImageSource([imageRef: ctx.makeImage()!])
    }

    @Test func twoPageBook_pagesTrimTextAndEmbeddedFonts() throws {
        let data = try PDFExporter.standardPDFData(Self.book(), images: Self.images())
        let document = try #require(PDFDocument(data: data))

        #expect(document.pageCount == 2)
        for index in 0..<2 {
            let page = try #require(document.page(at: index))
            #expect(page.bounds(for: .mediaBox) == CGRect(x: 0, y: 0, width: 612, height: 792))
            let pageText = normalise(page.string ?? "")
            #expect(pageText.contains(normalise("Page \(index + 1). " + Self.pageTexts[index])))
        }
        #expect(!document.findString("Tuesdays", withOptions: []).isEmpty)
        #expect(document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String == "The Fox Book")

        // The text sits inside the text box (y-up PDF space): selection bounds, not characterBounds (SL-1).
        let page0 = try #require(document.page(at: 0))
        let hit = try #require(document.findString("castle gate", withOptions: []).first)
        let bounds = hit.bounds(for: page0)
        let textBoxPDF = CGRect(x: 0.06 * 612, y: 792 - 0.94 * 792, width: 0.88 * 612, height: 0.24 * 792)
        #expect(textBoxPDF.contains(bounds))

        // Fonts: both faces embedded as subsets.
        let provider = try #require(CGDataProvider(data: data as CFData))
        let cgDoc = try #require(CGPDFDocument(provider))
        let pageDict = try #require(cgDoc.page(at: 1)?.dictionary)
        let fonts = PDFFonts.fonts(inPage: pageDict)
        #expect(fonts.count >= 2)
        #expect(fonts.allSatisfy { $0.isEmbedded })
        #expect(fonts.allSatisfy { $0.isSubset })
        #expect(fonts.contains { $0.baseFont.hasSuffix("+AtkinsonHyperlegible-Regular") })
        #expect(fonts.contains { $0.baseFont.hasSuffix("+AtkinsonHyperlegible-Bold") })
    }

    @Test func exportStandard_writesFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bookbook-pdf-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try PDFExporter.exportStandard(Self.book(), images: Self.images(), to: url)
        #expect(PDFDocument(url: url)?.pageCount == 2)
    }

    @Test func coverOnlyBook_throwsNoPages() {
        var content = Self.book()
        content.book.pageOrder = []
        #expect(throws: PDFExportError.noPages) {
            try PDFExporter.standardPDFData(content, images: Self.images())
        }
    }

    private func normalise(_ s: String) -> String {
        s.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }
}

@MainActor
final class ImageSource: PageImageSource {
    let images: [ImageRef: CGImage]
    init(_ images: [ImageRef: CGImage]) { self.images = images }
    func image(for ref: ImageRef) -> CGImage? { images[ref] }
}

/// Walks a CGPDF page's `/Resources /Font` (and Form XObjects) and reports each font (as SL-1).
enum PDFFonts {
    struct Info {
        let baseFont: String
        let fontFileKeys: [String]
        var isEmbedded: Bool { !fontFileKeys.isEmpty }
        var isSubset: Bool {
            let parts = baseFont.split(separator: "+", maxSplits: 1)
            return parts.count == 2 && parts[0].count == 6 && parts[0].allSatisfy(\.isUppercase)
        }
    }

    static func fonts(inPage page: CGPDFDictionaryRef) -> [Info] {
        var result: [Info] = []
        var resources: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(page, "Resources", &resources), let resources {
            collect(resources, into: &result, depth: 0)
        }
        return result
    }

    private static func collect(_ resources: CGPDFDictionaryRef, into result: inout [Info], depth: Int) {
        var fontDict: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(resources, "Font", &fontDict), let fontDict {
            var found: [Info] = []
            CGPDFDictionaryApplyBlock(fontDict, { _, object, _ in
                var dict: CGPDFDictionaryRef?
                if CGPDFObjectGetValue(object, .dictionary, &dict), let dict { found.append(info(dict)) }
                return true
            }, nil)
            result += found
        }
        guard depth < 4 else { return }
        var xobjects: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects), let xobjects {
            var nested: [CGPDFDictionaryRef] = []
            CGPDFDictionaryApplyBlock(xobjects, { _, object, _ in
                var stream: CGPDFStreamRef?
                if CGPDFObjectGetValue(object, .stream, &stream), let stream, let dict = CGPDFStreamGetDictionary(stream) {
                    var res: CGPDFDictionaryRef?
                    if CGPDFDictionaryGetDictionary(dict, "Resources", &res), let res { nested.append(res) }
                }
                return true
            }, nil)
            for res in nested { collect(res, into: &result, depth: depth + 1) }
        }
    }

    private static func info(_ font: CGPDFDictionaryRef) -> Info {
        var name: UnsafePointer<CChar>?
        let baseFont = CGPDFDictionaryGetName(font, "BaseFont", &name) ? name.map { String(cString: $0) } ?? "?" : "?"
        var files = fontFiles(font)
        var descendants: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(font, "DescendantFonts", &descendants), let descendants {
            var child: CGPDFDictionaryRef?
            if CGPDFArrayGetDictionary(descendants, 0, &child), let child { files += fontFiles(child) }
        }
        return Info(baseFont: baseFont, fontFileKeys: files)
    }

    private static func fontFiles(_ dict: CGPDFDictionaryRef) -> [String] {
        var descriptor: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dict, "FontDescriptor", &descriptor), let descriptor else { return [] }
        return ["FontFile", "FontFile2", "FontFile3"].filter { key in
            var stream: CGPDFStreamRef?
            return CGPDFDictionaryGetStream(descriptor, key, &stream)
        }
    }
}
