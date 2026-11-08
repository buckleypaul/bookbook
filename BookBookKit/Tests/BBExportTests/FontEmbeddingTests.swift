import BBLayout
import BBModel
import BBTestSupport
import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import BBExport

/// A registered (not system-installed) font used in a text box must be embedded in the exported PDF.
@MainActor
@Suite("Font embedding")
struct FontEmbeddingTests {
    static let boxID = BoxID("00000000-0000-0000-0000-0000000000E1")

    static func book() -> BookContent {
        let template = Template(name: "Text", kind: .single, boxes: [
            Box(id: boxID, frame: NormalizedRect(x: 0.1, y: 0.1, width: 0.8, height: 0.3),
                content: .text(TextBoxStyle(padding: 6))),
        ])
        var content = BookContent.makeNew(title: "Fonts", storyTemplate: template,
                                          coverTemplate: Template(name: "Cover", kind: .cover, boxes: []),
                                          storyPageCount: 1, now: Date(timeIntervalSince1970: 0))
        content.style.typography = Typography(
            bodyFont: FontRef(postScriptName: "Helvetica"),
            titleFont: FontRef(postScriptName: "Helvetica-Bold"),
            bodySize: 18, color: .black, lineSpacing: 1.2, alignment: .leading)
        let pageID = content.book.pageOrder[0]
        var page = content.pages[pageID]!
        page.text[boxID] = RichText(paragraphs: [Paragraph(runs: [
            Run(text: "Plain and "),
            Run(text: "Atkinson text", fontFamily: TestFonts.Face.regular.rawValue),
        ])])
        content.pages[pageID] = page
        return content
    }

    @Test func registeredFontIsEmbeddedAsSubset() throws {
        let urls = TestFonts.Face.allCases.compactMap { TestFonts.url(for: $0) }
        #expect(FontRegistry.register(urls).isEmpty)
        let info = try FontInspector.inspect(try #require(TestFonts.url(for: .regular)))
        #expect(info.embeddingAllowed)

        let data = try PDFExporter.standardPDFData(Self.book(), images: EmptyImages())
        let document = try #require(PDFDocument(data: data))
        #expect(document.string?.contains("Atkinson text") == true) // still real text

        let provider = try #require(CGDataProvider(data: data as CFData))
        let cgDoc = try #require(CGPDFDocument(provider))
        let pageDict = try #require(cgDoc.page(at: 1)?.dictionary)
        let fonts = EmbeddedFonts.fonts(inPage: pageDict)
        let atkinson = try #require(fonts.first { $0.baseFont.hasSuffix("+AtkinsonHyperlegible-Regular") })
        #expect(atkinson.isEmbedded)
        #expect(atkinson.isSubset)
        #expect(fonts.allSatisfy { $0.isEmbedded })
    }
}

@MainActor
private final class EmptyImages: PageImageSource {
    func image(for ref: ImageRef) -> CGImage? { nil }
}

/// Walks a CGPDF page's `/Resources /Font` (and Form XObjects) and reports each font.
private enum EmbeddedFonts {
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
