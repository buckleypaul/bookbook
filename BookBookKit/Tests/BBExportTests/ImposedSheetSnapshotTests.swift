import AppKit
import BBModel
import BBTestSupport
import SnapshotTesting
import Testing
@testable import BBExport

/// Snapshots of imposed booklet sheets and a print-shop page (Phase 14 tests), each PDF page
/// rendered to an image.
@MainActor
@Suite("Imposed sheet snapshots")
struct ImposedSheetSnapshotTests {
    init() { #expect(TestFonts.registerAll()) }

    typealias F = ExportFixtures

    func sheet(_ content: BookContent, _ options: ExportOptions, page: Int, scale: CGFloat = 1) async throws -> NSImage {
        let (data, _) = try await F.exporter(content).pdfData(options) { _ in }
        let ctx = try #require(F.bitmap(data, page: page, scale: scale))
        return F.image(ctx, scale: scale)
    }

    @Test func booklet_halfLetterOnLetter_outerSheetFront() async throws {
        // Cover + inside-cover blank + 6 pages = 8: the outer front holds Leaf06 (left) and the
        // cover (right); the outer back holds the inside-cover blank (left) and Leaf05 (right).
        let image = try await sheet(F.book(pages: 6), ExportOptions(kind: .booklet(.letter)), page: 0)
        assertSnapshot(of: image, as: .image(precision: 0.99, perceptualPrecision: 0.97))
    }

    @Test func booklet_halfLetterOnLetter_outerSheetBack() async throws {
        let image = try await sheet(F.book(pages: 6), ExportOptions(kind: .booklet(.letter)), page: 1)
        assertSnapshot(of: image, as: .image(precision: 0.99, perceptualPrecision: 0.97))
    }

    @Test func booklet_letterPagesScaledOnLetter_withBlank() async throws {
        // Cover + inside-cover blank + 2 pages = 4: the outer front holds Leaf02 (left) and the cover.
        let content = F.book(pages: 2, trim: PointSize(width: 612, height: 792))
        let image = try await sheet(content, ExportOptions(kind: .booklet(.letter)), page: 0)
        assertSnapshot(of: image, as: .image(precision: 0.99, perceptualPrecision: 0.97))
    }

    @Test func booklet_landscapePagesStackedOnA4() async throws {
        // Cover + inside-cover blank + 6 pages = 8: Leaf06 on top, the cover below.
        let content = F.book(pages: 6, trim: PointSize(width: 576, height: 432))
        let image = try await sheet(content, ExportOptions(kind: .booklet(.a4)), page: 0)
        assertSnapshot(of: image, as: .image(precision: 0.99, perceptualPrecision: 0.97))
    }

    @Test func printShop_pageWithBleedAndCropMarks() async throws {
        var content = F.book(pages: 1, bleed: true)
        // Make the image box full-bleed at the top so the bleed is visible past the trim.
        for (id, var template) in content.templates where template.kind == .single {
            template.boxes[0].frame = NormalizedRect(x: 0, y: 0, width: 1, height: 0.55)
            template.boxes[0].bleedEdges = [.top, .leading, .trailing]
            content.templates[id] = template
        }
        let image = try await sheet(content, ExportOptions(kind: .printShop, includeCover: false), page: 0, scale: 2)
        assertSnapshot(of: image, as: .image(precision: 0.99, perceptualPrecision: 0.97))
    }
}
