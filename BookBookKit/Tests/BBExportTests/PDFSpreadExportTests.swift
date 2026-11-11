import BBLayout
import BBModel
import BBTestSupport
import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import BBExport

/// A spread-template page exports as two trim-size PDF pages, its left half then its right half
/// (PD §9 default "spreads as single pages"), numbered by position like the canvas.
@MainActor
@Suite("PDF spread export")
struct PDFSpreadExportTests {
    init() { #expect(TestFonts.registerAll()) }

    static let leftBox = BoxID("00000000-0000-0000-0000-0000000000D1")
    static let rightBox = BoxID("00000000-0000-0000-0000-0000000000D2")

    /// Cover, then story pages [single, spread, single] at positions 1, 2–3, 4. The spread has a
    /// red panel with "Leftwords" on its left half, a blue one with "Rightwords" on its right, and
    /// a green band across the fold.
    static func book(position: PageNumberPosition = .bottomOuter) -> BookContent {
        let single = Template(name: "Text", kind: .single, boxes: [
            Box(frame: NormalizedRect(x: 0.1, y: 0.1, width: 0.8, height: 0.6), content: .text(TextBoxStyle())),
        ])
        let spread = Template(name: "Spread", kind: .spread, boxes: [
            Box(id: leftBox, frame: NormalizedRect(x: 0.05, y: 0.1, width: 0.35, height: 0.4),
                content: .text(TextBoxStyle(padding: 8, background: RGBA(red: 0.9, green: 0.1, blue: 0.1, alpha: 1)))),
            Box(id: rightBox, frame: NormalizedRect(x: 0.6, y: 0.1, width: 0.35, height: 0.4),
                content: .text(TextBoxStyle(padding: 8, background: RGBA(red: 0.1, green: 0.1, blue: 0.9, alpha: 1)))),
            Box(frame: NormalizedRect(x: 0.3, y: 0.6, width: 0.4, height: 0.15),
                content: .text(TextBoxStyle(background: RGBA(red: 0.1, green: 0.8, blue: 0.2, alpha: 1)))),
        ])
        var content = BookContent.makeNew(title: "", storyTemplate: single,
                                          coverTemplate: Template(name: "Cover", kind: .cover, boxes: []),
                                          storyPageCount: 3, now: Date(timeIntervalSince1970: 0))
        content.templates[spread.id] = spread
        let spreadPageID = content.book.pageOrder[1]
        content.pages[spreadPageID]?.templateID = spread.id
        content.pages[spreadPageID]?.text[leftBox] = RichText(paragraphs: [Paragraph(runs: [Run(text: "Leftwords")])])
        content.pages[spreadPageID]?.text[rightBox] = RichText(paragraphs: [Paragraph(runs: [Run(text: "Rightwords")])])
        content.style.typography.bodyFont = FontRef(postScriptName: TestFonts.Face.regular.rawValue)
        content.style.pageNumbers = PageNumberStyle(enabled: true, position: position,
                                                    fontFamily: TestFonts.Face.regular.rawValue)
        return content
    }

    static func pdf(_ content: BookContent) async throws -> PDFDocument {
        let data = try await ExportFixtures.standardPDF(content, images: ImageSource([:]))
        return try #require(PDFDocument(data: data))
    }

    @Test func spreadBecomesTwoTrimSizePages() async throws {
        let content = Self.book()
        let document = try await Self.pdf(content)
        let trim = PageGeometry(setup: content.style.pageSetup).trimRect
        // Cover + single + 2 spread halves + single.
        #expect(document.pageCount == content.storyPages.count + 2)
        for index in 0..<document.pageCount {
            #expect(document.page(at: index)?.bounds(for: .mediaBox) == trim)
        }
        let texts = (0..<document.pageCount).map {
            (document.page(at: $0)?.string ?? "").components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
        }
        #expect(texts[0].isEmpty) // cover, never numbered
        #expect(texts[1] == ["1"])
        #expect(texts[2].contains("Leftwords") && !texts[2].contains("Rightwords"))
        #expect(texts[2].contains("2") && !texts[2].contains("3"))
        #expect(texts[3].contains("Rightwords") && !texts[3].contains("Leftwords"))
        #expect(texts[3].contains("3") && !texts[3].contains("2"))
        #expect(texts[4] == ["4"])
    }

    @Test func pageNumbersSitOnTheOuterEdgeOfEachHalf() async throws {
        let content = Self.book(position: .bottomOuter)
        let document = try await Self.pdf(content)
        let width = PageGeometry(setup: content.style.pageSetup).trimSize.width
        func numberBounds(_ text: String, page index: Int) throws -> CGRect {
            let page = try #require(document.page(at: index))
            let hit = try #require(document.findString(text, withOptions: []).first { $0.pages.first == page })
            return hit.bounds(for: page)
        }
        // Position 2 is a left-hand page (outer = left edge); position 3 right-hand (outer = right).
        let left = try numberBounds("2", page: 2)
        let right = try numberBounds("3", page: 3)
        #expect(left.minX >= 0 && left.maxX < width / 2)
        #expect(right.minX > width / 2 && right.maxX <= width)
        // Bottom margin band (PDF space is y-up).
        #expect(left.maxY < 72 && right.maxY < 72)
    }

    @Test func eachHalfMatchesTheSpreadDrawnAtDoubleWidth() async throws {
        let content = Self.book()
        let document = try await Self.pdf(content)
        let spreadPage = try #require(content.pages[content.book.pageOrder[1]])
        let trim = PageGeometry(setup: content.style.pageSetup).trimSize
        let scale: CGFloat = 0.5
        let w = Int(trim.width * scale), h = Int(trim.height * scale)

        // Reference: the whole spread at double width, as the canvas draws it.
        let reference = Bitmap(width: w * 2, height: h)
        reference.ctx.translateBy(x: 0, y: CGFloat(h))
        reference.ctx.scaleBy(x: scale, y: -scale)
        PageRenderer(images: ImageSource([:])).draw(
            page: spreadPage, in: content, into: reference.ctx,
            options: RenderOptions(target: .pdfTrim, pageNumbers: PageNumberMarks(content: content).marks(for: spreadPage.id)))

        for half in 0..<2 {
            let page = try #require(document.page(at: 2 + half)?.pageRef)
            let raster = Bitmap(width: w, height: h)
            raster.ctx.scaleBy(x: scale, y: scale)
            raster.ctx.drawPDFPage(page)
            var differing = 0
            for y in 0..<h {
                for x in 0..<w where raster.maxChannelDifference(x: x, y: y, other: reference, ox: x + half * w, oy: y) > 48 {
                    differing += 1
                }
            }
            #expect(Double(differing) / Double(w * h) < 0.005, "half \(half): \(differing) pixels differ")
        }

        // Spot checks (y-down from the top): left half shows red, right half blue, both green at the fold.
        let left = Bitmap(width: w, height: h), right = Bitmap(width: w, height: h)
        left.ctx.scaleBy(x: scale, y: scale)
        right.ctx.scaleBy(x: scale, y: scale)
        left.ctx.drawPDFPage(try #require(document.page(at: 2)?.pageRef))
        right.ctx.drawPDFPage(try #require(document.page(at: 3)?.pageRef))
        let panelY = Int(0.45 * Double(h)), bandY = Int(0.7 * Double(h))
        #expect(left.rgb(x: Int(0.15 * Double(w)), y: panelY).r > 200)
        #expect(right.rgb(x: Int(0.85 * Double(w)), y: panelY).b > 200)
        #expect(left.rgb(x: w - 4, y: bandY).g > 150)
        #expect(right.rgb(x: 4, y: bandY).g > 150)
        #expect(left.rgb(x: Int(0.85 * Double(w)), y: panelY) == (255, 255, 255))
    }
}

/// An sRGB RGBA bitmap filled white. Rows are stored top first, so pixel (x, y) is y-down.
@MainActor
final class Bitmap {
    let width: Int, height: Int
    let ctx: CGContext

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }

    func rgb(x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        let p = ctx.data!.assumingMemoryBound(to: UInt8.self) + (y * width + x) * 4
        return (p[0], p[1], p[2])
    }

    func maxChannelDifference(x: Int, y: Int, other: Bitmap, ox: Int, oy: Int) -> Int {
        let a = rgb(x: x, y: y), b = other.rgb(x: ox, y: oy)
        return max(abs(Int(a.r) - Int(b.r)), abs(Int(a.g) - Int(b.g)), abs(Int(a.b) - Int(b.b)))
    }
}
