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
        let rect = BookletImposition.pageRect(in: layout.firstSlot, pageSize: page, scale: layout.scale)
        #expect(abs(rect.midX - layout.firstSlot.midX) < 1e-9 && abs(rect.midY - layout.firstSlot.midY) < 1e-9)
        #expect(rect.width <= layout.firstSlot.width + 1e-9 && rect.height <= layout.firstSlot.height + 1e-9)
    }

    @Test func landscapePages_stackOnPortraitSheet() {
        let layout = BookletImposition.layout(pageSize: CGSize(width: 720, height: 576), sheet: .tabloid)
        #expect(layout.sheetSize == CGSize(width: 792, height: 1224))
        #expect(layout.firstSlot == CGRect(x: 0, y: 0, width: 792, height: 612))
        #expect(layout.secondSlot == CGRect(x: 0, y: 612, width: 792, height: 612))
        #expect(layout.scale == 1)
        #expect(layout.printingInstructions == "Print double-sided, flip on short edge.")
    }

    /// Duplex model: a flip turns the sheet over about an axis through its centre. A short-edge
    /// flip is about the axis parallel to the short edges, so it mirrors the long dimension
    /// (x on a landscape sheet, y on a portrait one); a long-edge flip mirrors the short one.
    /// Returns the back-side slot (0 = first, 1 = second) behind front slot `slot`.
    static func backSlot(behind slot: Int, layout: BookletSheetLayout, shortEdge: Bool) -> Int {
        let slots = [layout.firstSlot, layout.secondSlot]
        let size = layout.sheetSize
        let mirrorX = (size.width >= size.height) == shortEdge
        let centre = CGPoint(x: slots[slot].midX, y: slots[slot].midY)
        let behind = mirrorX ? CGPoint(x: size.width - centre.x, y: centre.y)
                             : CGPoint(x: centre.x, y: size.height - centre.y)
        return slots.firstIndex { $0.contains(behind) }!
    }

    static func flipsOnShortEdge(_ layout: BookletSheetLayout) -> Bool {
        layout.printingInstructions.contains("short edge")
    }

    /// In a folded booklet each leaf carries page 2k − 1 on its front (recto) and 2k on its back,
    /// so with the stated flip, the page behind every front-side page must be its leaf partner.
    @Test(arguments: [(CGSize(width: 396, height: 612), SheetSize.letter),   // side by side
                      (CGSize(width: 720, height: 576), SheetSize.tabloid),  // stacked
                      (CGSize(width: 576, height: 432), SheetSize.a4)])      // stacked
    func duplex_backPageBacksItsLeafPartner(page: CGSize, sheet: SheetSize) {
        let layout = BookletImposition.layout(pageSize: page, sheet: sheet)
        let shortEdge = Self.flipsOnShortEdge(layout)
        for n in stride(from: 4, through: 16, by: 4) {
            let sides = BookletImposition.sheetSides(pageCount: n)
            for s in 0..<(n / 4) {
                let front = sides[s * 2], back = sides[s * 2 + 1]
                let frontPages = [front.leftPage, front.rightPage], backPages = [back.leftPage, back.rightPage]
                for slot in 0..<2 {
                    let p = frontPages[slot]
                    let partner = p % 2 == 1 ? p + 1 : p - 1
                    #expect(backPages[Self.backSlot(behind: slot, layout: layout, shortEdge: shortEdge)] == partner,
                            "n = \(n), sheet \(s), front page \(p)")
                }
            }
        }
        // Concretely, on the outer sheet page 2 backs page 1 and n − 1 backs n; the other
        // flip would back page 1 with n − 1.
        let sides = BookletImposition.sheetSides(pageCount: 8)
        let behindCover = [sides[1].leftPage, sides[1].rightPage][Self.backSlot(behind: 1, layout: layout,
                                                                                 shortEdge: shortEdge)]
        #expect(behindCover == 2)
        let wrong = [sides[1].leftPage, sides[1].rightPage][Self.backSlot(behind: 1, layout: layout,
                                                                           shortEdge: !shortEdge)]
        #expect(wrong == 7)
    }

    @Test func duplex_stackedBackStaysUprightWhenOpened() {
        // Stacked: folding on the horizontal centre line and opening turns the back over about
        // that line, which is what a short-edge flip of a portrait sheet does, so back content
        // drawn upright in the PDF reads upright in the opened booklet. A long-edge flip turns
        // it over about the vertical axis instead (the back would read upside down).
        let layout = BookletImposition.layout(pageSize: CGSize(width: 720, height: 576), sheet: .tabloid)
        #expect(layout.sheetSize.height > layout.sheetSize.width)
        #expect(layout.firstSlot.maxY == layout.secondSlot.minY) // fold is horizontal
        #expect(Self.flipsOnShortEdge(layout))
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
