import CoreGraphics
import Testing
@testable import BBExport

/// A §9.3 imposition order, booklet sheet layout, and print-shop crop-mark geometry.
@Suite("Booklet imposition and crop marks")
struct BookletImpositionTests {
    @Test(arguments: stride(from: 4, through: 32, by: 4).map { $0 })
    func ordering_everyPageOnceAndFoldsInOrder(n: Int) {
        let sides = BookletImposition.sheetSides(pageCount: n)
        #expect(sides.count == n / 2)
        let pages = sides.flatMap { [$0.leftPage, $0.rightPage] }
        #expect(pages.sorted() == Array(1...n))
        for side in sides { #expect(side.leftPage + side.rightPage == n + 1) }
        // Fronts then backs alternate per sheet, outer sheet first.
        for (index, side) in sides.enumerated() {
            #expect(side.sheet == index / 2)
            #expect(side.isFront == (index % 2 == 0))
        }
        // Fold simulation: nest sheets (outer first), and read each sheet's right half front,
        // then back, then (on the way out) the left halves. That must give 1…n.
        var firstHalf: [Int] = []
        var secondHalf: [Int] = []
        for sheet in 0..<(n / 4) {
            let front = sides[sheet * 2], back = sides[sheet * 2 + 1]
            // Opening a folded stack: page on the front right, then the back left.
            firstHalf += [front.rightPage, back.leftPage]
            // Back half of the book: back right, then front left, inner sheets first.
            secondHalf.insert(contentsOf: [back.rightPage, front.leftPage], at: 0)
        }
        #expect(firstHalf + secondHalf == Array(1...n))
    }

    @Test(arguments: [(1, 4), (4, 4), (5, 8), (10, 12), (12, 12), (13, 16), (31, 32)])
    func paddedCount(n: Int, expected: Int) {
        #expect(BookletImposition.paddedCount(n) == expected)
    }

    @Test func halfLetterOnLetter_fitsAtFullSize() {
        let layout = BookletImposition.layout(pageSize: CGSize(width: 396, height: 612), sheet: .letter)
        #expect(layout.sheetSize == CGSize(width: 792, height: 612))
        #expect(layout.scale == 1)
        #expect(!layout.scaledToFit)
        #expect(layout.firstSlot == CGRect(x: 0, y: 0, width: 396, height: 612))
        #expect(layout.secondSlot == CGRect(x: 396, y: 0, width: 396, height: 612))
        #expect(layout.printingInstructions == "Print double-sided, flip on short edge.")
    }

    @Test func a5OnA4_fitsAtFullSize() {
        let layout = BookletImposition.layout(pageSize: CGSize(width: 419.53, height: 595.28), sheet: .a4)
        #expect(layout.scale == 1)
        #expect(!layout.scaledToFit)
        #expect(layout.sheetSize.width > layout.sheetSize.height)
    }

    @Test func letterPagesOnLetter_scaleToFitAndCentre() {
        let page = CGSize(width: 612, height: 792)
        let layout = BookletImposition.layout(pageSize: page, sheet: .letter)
        #expect(layout.scaledToFit)
        #expect(abs(layout.scale - 396.0 / 612.0) < 1e-9)
        let rect = BookletLayoutEngine.pageRect(in: layout.firstSlot, pageSize: page, scale: layout.scale)
        #expect(abs(rect.midX - layout.firstSlot.midX) < 1e-9 && abs(rect.midY - layout.firstSlot.midY) < 1e-9)
        #expect(rect.width <= layout.firstSlot.width + 1e-9 && rect.height <= layout.firstSlot.height + 1e-9)
    }

    @Test func landscapePages_stackOnPortraitSheet() {
        let layout = BookletImposition.layout(pageSize: CGSize(width: 720, height: 576), sheet: .tabloid)
        #expect(layout.sheetSize == CGSize(width: 792, height: 1224))
        #expect(layout.firstSlot == CGRect(x: 0, y: 0, width: 792, height: 612))
        #expect(layout.secondSlot == CGRect(x: 0, y: 612, width: 792, height: 612))
        #expect(layout.scale == 1)
        #expect(layout.printingInstructions == "Print double-sided, flip on long edge.")
    }

    @Test(arguments: SheetSize.allCases)
    func everySheetSize_hasInstructionsAndScaleAtMostOne(sheet: SheetSize) {
        let layout = BookletImposition.layout(pageSize: CGSize(width: 576, height: 576), sheet: sheet)
        #expect(layout.scale <= 1 && layout.scale > 0)
        #expect(layout.printingInstructions.hasPrefix("Print double-sided"))
    }

    @Test func cropMarks_eightSegmentsOnTrimExtensionsInMarkArea() {
        let bleed: CGFloat = 9
        let margin = bleed + CropMarks.markArea
        let trim = CGRect(x: margin, y: margin, width: 396, height: 612)
        let media = trim.insetBy(dx: -margin, dy: -margin)
        let bleedRect = trim.insetBy(dx: -bleed, dy: -bleed)
        let segments = CropMarks.segments(trim: trim, bleed: bleed)
        #expect(segments.count == 8)
        for segment in segments {
            let horizontal = segment.start.y == segment.end.y
            let vertical = segment.start.x == segment.end.x
            #expect(horizontal != vertical)
            // On a trim line's extension.
            if horizontal { #expect([trim.minY, trim.maxY].contains(segment.start.y)) }
            if vertical { #expect([trim.minX, trim.maxX].contains(segment.start.x)) }
            // Inside the media, outside the bleed (offset by 3 pt), reaching the media edge.
            for point in [segment.start, segment.end] {
                #expect(media.insetBy(dx: -0.001, dy: -0.001).contains(point))
                #expect(!bleedRect.insetBy(dx: -CropMarks.offsetFromBleed + 0.001,
                                           dy: -CropMarks.offsetFromBleed + 0.001).contains(point))
            }
            let length = hypot(segment.end.x - segment.start.x, segment.end.y - segment.start.y)
            #expect(abs(length - (CropMarks.markArea - CropMarks.offsetFromBleed)) < 1e-9)
            let touchesEdge = [segment.start, segment.end].contains {
                $0.x == media.minX || $0.x == media.maxX || $0.y == media.minY || $0.y == media.maxY
            }
            #expect(touchesEdge)
        }
        // Two per corner.
        for corner in [CGPoint(x: trim.minX, y: trim.minY), CGPoint(x: trim.maxX, y: trim.minY),
                       CGPoint(x: trim.minX, y: trim.maxY), CGPoint(x: trim.maxX, y: trim.maxY)] {
            let near = segments.filter { s in
                (s.start.x == corner.x || s.start.y == corner.y)
                    && hypot(s.end.x - corner.x, s.end.y - corner.y) <= margin + 0.001
                    && hypot(s.start.x - corner.x, s.start.y - corner.y) <= margin + 0.001
            }
            #expect(near.count == 2)
        }
    }
}
