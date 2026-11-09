import BBLayout
import BBModel
import BBTestSupport
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Testing
@testable import BBExport

/// The Phase 14 export pipeline (A §9.1, §9.3, PD §8.8).
@MainActor
@Suite("BookExporter")
struct BookExporterTests {
    init() { #expect(TestFonts.registerAll()) }

    typealias F = ExportFixtures

    func pdf(_ content: BookContent, _ options: ExportOptions = ExportOptions(),
             preparer: FakePreparer = FakePreparer()) async throws -> (PDFDocument, ExportResult, Data) {
        let (data, result) = try await F.exporter(content, preparer: preparer).pdfData(options) { _ in }
        return (try #require(PDFDocument(data: data)), result, data)
    }

    // MARK: Standard

    @Test func standard_coverThenPagesAtTrim() async throws {
        let (doc, result, _) = try await pdf(F.book(pages: 3))
        #expect(doc.pageCount == 4)
        #expect(result.pageCount == 4)
        #expect(result.blanksAdded == 0 && result.printingInstructions == nil)
        for i in 0..<4 { #expect(doc.page(at: i)?.bounds(for: .mediaBox) == CGRect(x: 0, y: 0, width: 396, height: 612)) }
        #expect(F.words(doc) == [["Coverword"], [F.leaf(1)], [F.leaf(2)], [F.leaf(3)]])
        #expect(doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String == "Coverword")
    }

    @Test func standard_excludeCoverAndPageRange() async throws {
        let options = ExportOptions(includeCover: false, pageRange: 2...3)
        let (doc, _, _) = try await pdf(F.book(pages: 5), options)
        #expect(F.words(doc) == [[F.leaf(2)], [F.leaf(3)]])
    }

    @Test func pageRange_includesSpreadWhenAnyPositionIsInside() async throws {
        // Positions: Leaf01 = 1, spread Leaf02 = 2–3, Leaf03 = 4.
        let content = F.book(pages: 3, spreads: [1])
        let (doc, _, _) = try await pdf(content, ExportOptions(includeCover: false, pageRange: 3...3))
        #expect(F.words(doc) == [[F.leaf(2) + "a"], [F.leaf(2) + "b"]])
        let (tail, _, _) = try await pdf(content, ExportOptions(includeCover: false, pageRange: 4...9))
        #expect(F.words(tail) == [[F.leaf(3)]])
    }

    @Test func emptySelection_throwsNoPages() async {
        let content = F.book(pages: 2)
        await #expect(throws: ExportError.noPages) {
            _ = try await F.exporter(content).pdfData(ExportOptions(includeCover: false, pageRange: 7...9)) { _ in }
        }
    }

    @Test func spreads_singlePagesOrDoubleWidth() async throws {
        let content = F.book(pages: 3, spreads: [1])
        let (single, _, _) = try await pdf(content, ExportOptions(includeCover: false))
        #expect(single.pageCount == 4)
        #expect(F.words(single)[1] == [F.leaf(2) + "a"] && F.words(single)[2] == [F.leaf(2) + "b"])

        let (double, _, _) = try await pdf(content, ExportOptions(includeCover: false, spreads: .doubleWidth))
        #expect(double.pageCount == 3)
        #expect(double.page(at: 1)?.bounds(for: .mediaBox) == CGRect(x: 0, y: 0, width: 792, height: 612))
        #expect(double.page(at: 0)?.bounds(for: .mediaBox) == CGRect(x: 0, y: 0, width: 396, height: 612))
        #expect(F.words(double)[1] == [F.leaf(2) + "a", F.leaf(2) + "b"])
    }

    @Test func pageNumbers_drawnFromPageNumberMarks() async throws {
        let (doc, _, _) = try await pdf(F.book(pages: 2, numbering: true))
        let words = F.words(doc)
        #expect(words[0] == ["Coverword"])
        #expect(words[1].contains("1") && words[2].contains("2"))
    }

    @Test func fontsStayEmbedded() async throws {
        let (_, _, data) = try await pdf(F.book(pages: 1))
        let provider = try #require(CGDataProvider(data: data as CFData))
        let cgDoc = try #require(CGPDFDocument(provider))
        let pageDict = try #require(cgDoc.page(at: 2)?.dictionary)
        let fonts = PDFFonts.fonts(inPage: pageDict)
        #expect(!fonts.isEmpty)
        #expect(fonts.allSatisfy { $0.isEmbedded && $0.isSubset })
    }

    // MARK: Images

    @Test func preparedImagesAreDrawnInsteadOfSources() async throws {
        let preparer = FakePreparer()
        let content = F.book(pages: 2)
        let (_, _, data) = try await pdf(content, preparer: preparer)
        let prepared = await preparer.prepared
        #expect(Set(prepared.map(\.page)) == Set(content.book.pageOrder))
        // Image box centre: x 0.5, y 0.33 of the page. Green (prepared), not red (source).
        let ctx = try #require(F.bitmap(data, page: 1))
        let p = F.pixel(ctx, x: 198, y: 200)
        #expect(p.g > 200 && p.r < 40)
    }

    @Test func preparerFailure_throwsImageUnreadable() async {
        struct Boom: Error {}
        await #expect(throws: ExportError.imageUnreadable(F.imageRef)) {
            _ = try await F.exporter(F.book(pages: 1), preparer: FakePreparer(failure: Boom()))
                .pdfData(ExportOptions()) { _ in }
        }
    }

    // MARK: Progress and cancellation

    @Test func progress_reportedAfterEachUnit() async throws {
        var seen: [ExportProgress] = []
        _ = try await F.exporter(F.book(pages: 3)).pdfData(ExportOptions()) { seen.append($0) }
        #expect(seen.map(\.completedUnits) == [1, 2, 3, 4])
        #expect(seen.allSatisfy { $0.totalUnits == 4 })
        #expect(seen.last?.fraction == 1)
    }

    @Test func cancellation_throwsBetweenPages() async {
        let exporter = F.exporter(F.book(pages: 6))
        var units = 0
        let task = Task { @MainActor in
            try await exporter.pdfData(ExportOptions()) { _ in
                units += 1
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(units == 1)
    }

    @Test func cancelledExport_leavesNoFile() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bb-cancel-\(UUID().uuidString).pdf")
        let exporter = F.exporter(F.book(pages: 3))
        let task = Task { @MainActor in
            try await exporter.export(ExportOptions(), to: url) { _ in withUnsafeCurrentTask { $0?.cancel() } }
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(!FileManager.default.fileExists(atPath: url.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
            .filter { $0.contains(url.lastPathComponent) }
        #expect(leftovers.isEmpty)
    }

    @Test func export_writesFile() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bb-export-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try await F.exporter(F.book(pages: 2)).export(ExportOptions(), to: url) { _ in }
        #expect(result.pageCount == 3)
        #expect(PDFDocument(url: url)?.pageCount == 3)
        // Overwrites an existing file.
        _ = try await F.exporter(F.book(pages: 1)).export(ExportOptions(), to: url) { _ in }
        #expect(PDFDocument(url: url)?.pageCount == 2)
    }

    // MARK: Print shop

    @Test func printShop_requiresBleed() async {
        await #expect(throws: ExportError.bleedRequired) {
            _ = try await F.exporter(F.book(pages: 1)).pdfData(ExportOptions(kind: .printShop)) { _ in }
        }
    }

    @Test func printShop_mediaTrimAndBleedBoxes() async throws {
        let (doc, result, _) = try await pdf(F.book(pages: 2, bleed: true), ExportOptions(kind: .printShop))
        #expect(result.pageCount == 3)
        let margin: CGFloat = 9 + 18
        for i in 0..<doc.pageCount {
            let page = try #require(doc.page(at: i))
            #expect(page.bounds(for: .mediaBox) == CGRect(x: 0, y: 0, width: 396 + 2 * margin, height: 612 + 2 * margin))
            #expect(page.bounds(for: .trimBox) == CGRect(x: margin, y: margin, width: 396, height: 612))
            #expect(page.bounds(for: .bleedBox) == CGRect(x: 18, y: 18, width: 396 + 18, height: 612 + 18))
        }
        #expect(F.words(doc)[1] == [F.leaf(1)])
    }

    @Test func printShop_doubleWidthSpreadBoxes() async throws {
        let content = F.book(pages: 2, bleed: true, spreads: [1])
        let (doc, _, _) = try await pdf(content, ExportOptions(kind: .printShop, includeCover: false, spreads: .doubleWidth))
        let page = try #require(doc.page(at: 1))
        #expect(page.bounds(for: .trimBox) == CGRect(x: 27, y: 27, width: 792, height: 612))
    }

    @Test func printShop_cropMarksInkedOutsideBleed() async throws {
        let (_, _, data) = try await pdf(F.book(pages: 1, bleed: true), ExportOptions(kind: .printShop))
        let ctx = try #require(F.bitmap(data, page: 1, scale: 4))
        // Top-left mark: horizontal along trim top (y = 27 pt), x from 0 to 15 pt.
        let markPixel = F.pixel(ctx, x: 6 * 4, y: 27 * 4)
        #expect(markPixel.r < 200)
        // Corner region inside the mark area but off the trim lines is white.
        let blank = F.pixel(ctx, x: 6 * 4, y: 10 * 4)
        #expect(blank.r > 250 && blank.g > 250)
    }

    // MARK: Booklet

    @Test func booklet_tenPagesOnLetter_reportsBlanksAndInstructions() async throws {
        let content = F.book(pages: 10)
        let (doc, result, _) = try await pdf(content, ExportOptions(kind: .booklet(.letter), includeCover: false))
        #expect(result.blanksAdded == 2)
        #expect(result.pageCount == 6) // 12 pages = 3 sheets, 6 sides
        #expect(doc.pageCount == 6)
        #expect(result.scale == 1 && !result.scaledToFit)
        #expect(result.printingInstructions == "Print double-sided, flip on short edge.")
        for i in 0..<doc.pageCount {
            #expect(doc.page(at: i)?.bounds(for: .mediaBox) == CGRect(x: 0, y: 0, width: 792, height: 612))
        }

        // With the cover as page 1: 11 → 12, one blank.
        let (_, withCover, _) = try await pdf(content, ExportOptions(kind: .booklet(.letter)))
        #expect(withCover.blanksAdded == 1)
    }

    @Test func booklet_sheetSidesCarryImposedPages() async throws {
        // Cover + 7 pages = 8: front 0 (8, 1=cover), back 0 (2, 7), front 1 (6, 3), back 1 (4, 5).
        let (doc, result, _) = try await pdf(F.book(pages: 7), ExportOptions(kind: .booklet(.letter)))
        #expect(result.blanksAdded == 0)
        let names = ["Coverword"] + (1...7).map(F.leaf)
        let sides = BookletImposition.sheetSides(pageCount: 8)
        let words = F.words(doc)
        for (index, side) in sides.enumerated() {
            let left = names[side.leftPage - 1], right = names[side.rightPage - 1]
            #expect(Set(words[index]) == [left, right])
            let page = try #require(doc.page(at: index))
            // The left page sits in the left half of the landscape sheet, the right page in the right.
            for (name, isLeft) in [(left, true), (right, false)] {
                let hit = try #require(doc.findString(name, withOptions: []).first { $0.pages.contains(page) })
                #expect((hit.bounds(for: page).midX < 396) == isLeft, "\(name) on side \(index)")
            }
        }
    }

    @Test func booklet_spreadsBecomeHalves_coverExcluded() async throws {
        // Leaf01, spread Leaf02 (a, b), Leaf03 = 4 booklet pages.
        let content = F.book(pages: 3, spreads: [1])
        let (doc, result, _) = try await pdf(content, ExportOptions(kind: .booklet(.letter), includeCover: false,
                                                                    spreads: .doubleWidth))
        #expect(result.blanksAdded == 0)
        #expect(F.words(doc) == [[F.leaf(3), F.leaf(1)], [F.leaf(2) + "a", F.leaf(2) + "b"]])
    }

    @Test func booklet_scalesLetterPagesOnLetter() async throws {
        let (_, result, _) = try await pdf(F.book(pages: 3, trim: PointSize(width: 612, height: 792)),
                                           ExportOptions(kind: .booklet(.letter)))
        #expect(result.scaledToFit)
        #expect(abs(result.scale - 396.0 / 612.0) < 1e-9)
    }

    @Test func coverPDF_isCoverAlone() async throws {
        let data = try await F.exporter(F.book(pages: 4)).coverPDFData()
        let doc = try #require(PDFDocument(data: data))
        #expect(doc.pageCount == 1)
        #expect(F.words(doc) == [["Coverword"]])
        #expect(doc.page(at: 0)?.bounds(for: .mediaBox) == CGRect(x: 0, y: 0, width: 396, height: 612))
    }

    // MARK: Bitmaps

    @Test(arguments: [BitmapFormat.png, .jpeg])
    func bitmap_is300DPI(format: BitmapFormat) async throws {
        let content = F.book(pages: 2)
        let data = try await F.exporter(content).bitmapData(page: content.book.pageOrder[0], format: format)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 396 * 300 / 72 && image.height == 612 * 300 / 72)
        let type = CGImageSourceGetType(source) as String?
        #expect(type == (format == .png ? "public.png" : "public.jpeg"))
    }

    @Test func bitmap_spreadIsDoubleWidth() async throws {
        let content = F.book(pages: 2, spreads: [1])
        let data = try await F.exporter(content).bitmapData(page: content.book.pageOrder[1], format: .png)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 792 * 300 / 72 && image.height == 612 * 300 / 72)
    }
}
