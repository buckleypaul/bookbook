import BBModel
import CoreGraphics
import Testing
@testable import BBLayout

/// Phase 7: render-rect bleed expansion, safe areas per spread half, and focal points kept
/// across page-setup changes (stored placement unchanged, re-clamped at draw time).
@Suite("Page setup geometry")
struct PageSetupGeometryTests {
    static func setup(width: Double = 600, height: Double = 800, bleed: Bool, amount: Double = 9,
                      margins: EdgeInsetsPt = EdgeInsetsPt(all: 36)) -> PageSetup {
        PageSetup(trimSize: PointSize(width: width, height: height), orientation: .portrait, margins: margins,
                  bleedEnabled: bleed, bleedAmount: amount)
    }

    static let fullPage = NormalizedRect(x: 0, y: 0, width: 1, height: 1)

    // MARK: Render rect

    @Test(arguments: 0..<16)
    func renderRect_everyBleedEdgeCombination(rawEdges: Int) {
        let edges = EdgeSet(rawValue: rawEdges)
        let box = Box(frame: NormalizedRect(x: 0.1, y: 0.2, width: 0.5, height: 0.25), bleedEdges: edges, content: .image)
        let trim = CGRect(x: 60, y: 160, width: 300, height: 200)

        // Bleed off: the trim rect whatever the edges.
        #expect(PageGeometry(setup: Self.setup(bleed: false)).renderRect(for: box) == trim)

        // Bleed on: exactly the listed edges move out by the bleed.
        let geometry = PageGeometry(setup: Self.setup(bleed: true))
        let rect = geometry.renderRect(for: box)
        #expect(rect.minX == trim.minX - (edges.contains(.leading) ? 9 : 0))
        #expect(rect.maxX == trim.maxX + (edges.contains(.trailing) ? 9 : 0))
        #expect(rect.minY == trim.minY - (edges.contains(.top) ? 9 : 0))
        #expect(rect.maxY == trim.maxY + (edges.contains(.bottom) ? 9 : 0))
        #expect(geometry.pushedBleedEdges(for: box) == edges)
        // Round trip back to the stored frame.
        #expect(geometry.trimRect(fromRender: rect, pushedEdges: edges) == trim)
    }

    @Test func renderRect_bleedAmountIsHonoured() {
        let box = Box(frame: Self.fullPage, bleedEdges: .all, content: .image)
        let geometry = PageGeometry(setup: Self.setup(bleed: true, amount: 18))
        #expect(geometry.renderRect(for: box) == CGRect(x: -18, y: -18, width: 636, height: 836))
        #expect(geometry.bleedRect == geometry.renderRect(for: box))
        #expect(PageGeometry(setup: Self.setup(bleed: false)).bleedRect == CGRect(x: 0, y: 0, width: 600, height: 800))
    }

    @Test func renderRect_spreadDoesNotBleedAtTheFold() {
        // Spread of two 600×800 pages: fold at x = 600.
        let geometry = PageGeometry(setup: Self.setup(bleed: true), kind: .spread)
        #expect(geometry.isSpread && geometry.foldX == 600)
        let left = Box(frame: NormalizedRect(x: 0, y: 0, width: 0.5, height: 1), bleedEdges: .all, content: .image)
        let right = Box(frame: NormalizedRect(x: 0.5, y: 0, width: 0.5, height: 1), bleedEdges: .all, content: .image)
        let across = Box(frame: Self.fullPage, bleedEdges: .all, content: .image)
        #expect(geometry.renderRect(for: left) == CGRect(x: -9, y: -9, width: 609, height: 818))
        #expect(geometry.renderRect(for: right) == CGRect(x: 600, y: -9, width: 609, height: 818))
        #expect(geometry.renderRect(for: across) == CGRect(x: -9, y: -9, width: 1218, height: 818))
        #expect(geometry.pushedBleedEdges(for: left) == [.top, .leading, .bottom])
        #expect(geometry.pushedBleedEdges(for: right) == [.top, .bottom, .trailing])

        // A single page never treats its middle as a fold.
        let single = PageGeometry(setup: geometry.setup)
        #expect(single.renderRect(for: left).maxX == 609)
    }

    // MARK: Safe areas

    @Test func safeAreaPerSpreadHalf() {
        let margins = EdgeInsetsPt(top: 20, leading: 30, bottom: 40, trailing: 50)
        let spread = PageGeometry(setup: Self.setup(bleed: false, margins: margins), kind: .spread)
        #expect(spread.pageSafeAreas == [
            CGRect(x: 30, y: 20, width: 600 - 80, height: 740),
            CGRect(x: 630, y: 20, width: 600 - 80, height: 740),
        ])
        // Bleed on raises any margin below 0.125 in to 9 pt, on every page.
        let thin = EdgeInsetsPt(top: 2, leading: 4, bottom: 6, trailing: 8)
        let bled = PageGeometry(setup: Self.setup(bleed: true, margins: thin), kind: .spread)
        #expect(bled.pageSafeAreas == [
            CGRect(x: 9, y: 9, width: 582, height: 782),
            CGRect(x: 609, y: 9, width: 582, height: 782),
        ])
        // A single page has one.
        #expect(PageGeometry(setup: Self.setup(bleed: false, margins: margins)).pageSafeAreas.count == 1)
    }

    // MARK: Focal points across page-setup changes

    struct Change: Sendable, CustomTestStringConvertible {
        var name: String
        var imageSize: CGSize
        var from: CGSize
        var to: CGSize
        var zoom: Double
        var center: NormalizedPoint
        var testDescription: String { name }
    }

    static let changes: [Change] = [
        Change(name: "wide box → tall box, centred", imageSize: CGSize(width: 1536, height: 1024),
               from: CGSize(width: 1000, height: 100), to: CGSize(width: 100, height: 1000), zoom: 1,
               center: NormalizedPoint(x: 0.5, y: 0.5)),
        Change(name: "wide → tall, focal point at the top-left corner", imageSize: CGSize(width: 1024, height: 1024),
               from: CGSize(width: 1000, height: 100), to: CGSize(width: 100, height: 1000), zoom: 1,
               center: NormalizedPoint(x: 0, y: 0)),
        Change(name: "wide → tall, zoom 3, focal point near the right edge", imageSize: CGSize(width: 1024, height: 1536),
               from: CGSize(width: 1000, height: 100), to: CGSize(width: 100, height: 1000), zoom: 3,
               center: NormalizedPoint(x: 0.97, y: 0.4)),
        Change(name: "tall → wide, zoom 2, focal point near the bottom", imageSize: CGSize(width: 1536, height: 1024),
               from: CGSize(width: 120, height: 900), to: CGSize(width: 900, height: 120), zoom: 2,
               center: NormalizedPoint(x: 0.3, y: 0.99)),
        Change(name: "letter portrait → 10×8 landscape, zoom 1.5", imageSize: CGSize(width: 1024, height: 1536),
               from: CGSize(width: 612, height: 792), to: CGSize(width: 720, height: 576), zoom: 1.5,
               center: NormalizedPoint(x: 0.8, y: 0.1)),
        Change(name: "10×8 → 8×8, out-of-range focal point", imageSize: CGSize(width: 1536, height: 1024),
               from: CGSize(width: 720, height: 576), to: CGSize(width: 576, height: 576), zoom: 1,
               center: NormalizedPoint(x: 1.4, y: -0.3)),
    ]

    @Test(arguments: changes)
    func focalPointIsReclampedAndRestoredOnRevert(change: Change) {
        let placement = ImagePlacement(versionID: VersionID(), zoom: change.zoom, center: change.center,
                                       boxAspectWhenPlaced: change.from.width / change.from.height)
        let before = CGRect(origin: CGPoint(x: 10, y: 20), size: change.from)
        let after = CGRect(origin: CGPoint(x: 10, y: 20), size: change.to)

        for box in [before, after] {
            let rect = PageGeometry.imageRect(imageSize: change.imageSize, boxRect: box, placement: placement)
            // Always covers the box, at the image's aspect, scaled to aspect-fill × zoom.
            #expect(rect.minX <= box.minX + 1e-9 && rect.maxX >= box.maxX - 1e-9)
            #expect(rect.minY <= box.minY + 1e-9 && rect.maxY >= box.maxY - 1e-9)
            #expect(abs(rect.width / rect.height - change.imageSize.width / change.imageSize.height) < 1e-9)
            let fill = max(box.width / change.imageSize.width, box.height / change.imageSize.height)
            #expect(abs(rect.width - change.imageSize.width * fill * change.zoom) < 1e-6)
            // The focal point lands as close to the box centre as covering allows: on each
            // axis it's either exactly centred or the image is flush with a box edge.
            let cx = min(max(change.center.x, 0), 1), cy = min(max(change.center.y, 0), 1)
            let fx = rect.minX + cx * rect.width, fy = rect.minY + cy * rect.height
            #expect(abs(fx - box.midX) < 1e-6 || abs(rect.minX - box.minX) < 1e-6 || abs(rect.maxX - box.maxX) < 1e-6)
            #expect(abs(fy - box.midY) < 1e-6 || abs(rect.minY - box.minY) < 1e-6 || abs(rect.maxY - box.maxY) < 1e-6)
        }
        // Reverting the change gives back the original crop exactly (the placement is untouched).
        let original = PageGeometry.imageRect(imageSize: change.imageSize, boxRect: before, placement: placement)
        _ = PageGeometry.imageRect(imageSize: change.imageSize, boxRect: after, placement: placement)
        #expect(PageGeometry.imageRect(imageSize: change.imageSize, boxRect: before, placement: placement) == original)
    }

    @Test func focalPointClampTable() {
        // A 2:1 image in a 100×100 box at zoom 1 is 200×100: x slides in [-100, 0] (box at 0…100),
        // y is pinned. Each row: focal x → image minX.
        let box = CGRect(x: 0, y: 0, width: 100, height: 100)
        let rows: [(x: Double, minX: CGFloat)] = [(0, 0), (0.25, 0), (0.5, -50), (0.75, -100), (1, -100)]
        for row in rows {
            let p = ImagePlacement(versionID: VersionID(), center: NormalizedPoint(x: row.x, y: 0.9), boxAspectWhenPlaced: 1)
            let rect = PageGeometry.imageRect(imageSize: CGSize(width: 2, height: 1), boxRect: box, placement: p)
            #expect(rect.minX == row.minX, "focal x \(row.x)")
            #expect(rect.minY == 0 && rect.height == 100)
        }
        // The same image in a box made 4:1 by a page-setup change: now width-bound (400×200
        // covering 400×100), so x is pinned and y slides, clamped to the bottom edge.
        let wide = CGRect(x: 0, y: 0, width: 400, height: 100)
        let p = ImagePlacement(versionID: VersionID(), center: NormalizedPoint(x: 0.75, y: 0.9), boxAspectWhenPlaced: 1)
        let rect = PageGeometry.imageRect(imageSize: CGSize(width: 2, height: 1), boxRect: wide, placement: p)
        #expect(rect == CGRect(x: 0, y: -100, width: 400, height: 200))
    }

    @Test func degenerateInputsFallBackToTheBox() {
        let box = CGRect(x: 5, y: 5, width: 50, height: 50)
        let p = ImagePlacement(versionID: VersionID(), zoom: .infinity, center: NormalizedPoint(x: .nan, y: 0.5),
                               boxAspectWhenPlaced: 1)
        // Infinite zoom counts as 1; a NaN focal point counts as centred.
        #expect(PageGeometry.imageRect(imageSize: CGSize(width: 10, height: 10), boxRect: box, placement: p) == box)
        #expect(PageGeometry.imageRect(imageSize: .zero, boxRect: box, placement: p) == box)
        #expect(PageGeometry.imageRect(imageSize: CGSize(width: 10, height: 10), boxRect: .zero, placement: p) == .zero)
    }
}
