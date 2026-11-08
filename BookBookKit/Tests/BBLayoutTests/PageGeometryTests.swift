import BBModel
import CoreGraphics
import Testing
@testable import BBLayout

@Suite("PageGeometry")
struct PageGeometryTests {
    static let letter = PageSetup.letterPortrait
    static let fullBleedBox = Box(frame: NormalizedRect(x: 0, y: 0, width: 1, height: 0.5),
                                  bleedEdges: [.top, .leading, .trailing], content: .image)

    @Test func bleedOff_trimSafeAreaAndRenderRect() {
        let geometry = PageGeometry(setup: Self.letter)
        #expect(geometry.trimSize == CGSize(width: 612, height: 792))
        #expect(geometry.bleed == 0)
        #expect(geometry.safeArea == CGRect(x: 36, y: 36, width: 540, height: 720))
        // Bleed edges are ignored while bleed is off.
        #expect(geometry.renderRect(for: Self.fullBleedBox) == CGRect(x: 0, y: 0, width: 612, height: 396))
        let inner = Box(frame: NormalizedRect(x: 0.25, y: 0.5, width: 0.5, height: 0.25), content: .image)
        #expect(geometry.renderRect(for: inner) == CGRect(x: 153, y: 396, width: 306, height: 198))
    }

    @Test func bleedOn_pushesBleedEdgesOutAndEnforcesSafeInset() {
        var setup = Self.letter
        setup.bleedEnabled = true
        setup.margins = EdgeInsetsPt(top: 4, leading: 36, bottom: 0, trailing: 12)
        let geometry = PageGeometry(setup: setup)
        #expect(geometry.bleed == 9)
        // Top and bottom margins are below 0.125 in, so they become 9 pt.
        #expect(geometry.safeArea == CGRect(x: 36, y: 9, width: 612 - 36 - 12, height: 792 - 18))
        #expect(geometry.renderRect(for: Self.fullBleedBox) == CGRect(x: -9, y: -9, width: 630, height: 405))
        let bottomOnly = Box(frame: NormalizedRect(x: 0, y: 0.5, width: 1, height: 0.5),
                             bleedEdges: [.bottom], content: .image)
        #expect(geometry.renderRect(for: bottomOnly) == CGRect(x: 0, y: 396, width: 612, height: 405))
    }

    @Test func imageRect_wideImageFillsHeightAndCentres() {
        let box = CGRect(x: 10, y: 20, width: 200, height: 100)
        let placement = ImagePlacement(versionID: VersionID(), boxAspectWhenPlaced: 2)
        let rect = PageGeometry.imageRect(imageSize: CGSize(width: 1000, height: 250), boxRect: box, placement: placement)
        #expect(rect.height == 100)
        #expect(rect.width == 400)
        #expect(rect.midX == box.midX)
        #expect(rect.minY == box.minY)
        #expect(rect.contains(box))
    }

    @Test func imageRect_tallImageFillsWidthAndCentres() {
        let box = CGRect(x: 0, y: 0, width: 200, height: 100)
        let placement = ImagePlacement(versionID: VersionID(), boxAspectWhenPlaced: 2)
        let rect = PageGeometry.imageRect(imageSize: CGSize(width: 1024, height: 1536), boxRect: box, placement: placement)
        #expect(rect.width == 200)
        #expect(rect.height == 300)
        #expect(rect.midY == box.midY)
        #expect(rect.contains(box))
    }

    @Test func imageRect_zoomWithOffCentreFocalPointStaysCovering() {
        let box = CGRect(x: 50, y: 50, width: 300, height: 200)
        let size = CGSize(width: 1024, height: 1024)
        // Focal point near the top-left corner: clamped so the box stays covered.
        let corner = ImagePlacement(versionID: VersionID(), zoom: 2, center: NormalizedPoint(x: 0.05, y: 0.1),
                                    boxAspectWhenPlaced: 1.5)
        let rect = PageGeometry.imageRect(imageSize: size, boxRect: box, placement: corner)
        #expect(rect.width == 600)
        #expect(rect.height == 600)
        #expect(rect.minX == box.minX)
        #expect(rect.minY == box.minY)
        #expect(rect.contains(box))

        // A focal point that needs no clamping lands exactly at the box centre.
        let inside = ImagePlacement(versionID: VersionID(), zoom: 2, center: NormalizedPoint(x: 0.6, y: 0.4),
                                    boxAspectWhenPlaced: 1.5)
        let r2 = PageGeometry.imageRect(imageSize: size, boxRect: box, placement: inside)
        #expect(abs((r2.minX + 0.6 * r2.width) - box.midX) < 1e-9)
        #expect(abs((r2.minY + 0.4 * r2.height) - box.midY) < 1e-9)
        #expect(r2.contains(box))

        // Every focal point and zoom keeps the box covered.
        for zoom in [1.0, 1.5, 3.0] {
            for x in stride(from: 0.0, through: 1.0, by: 0.25) {
                for y in stride(from: 0.0, through: 1.0, by: 0.25) {
                    let p = ImagePlacement(versionID: VersionID(), zoom: zoom, center: NormalizedPoint(x: x, y: y),
                                           boxAspectWhenPlaced: 1.5)
                    #expect(PageGeometry.imageRect(imageSize: size, boxRect: box, placement: p).contains(box))
                }
            }
        }
    }

    @Test func imageRect_zoomBelowOneCountsAsOne() {
        let box = CGRect(x: 0, y: 0, width: 100, height: 100)
        let p = ImagePlacement(versionID: VersionID(), zoom: 0.5, boxAspectWhenPlaced: 1)
        #expect(PageGeometry.imageRect(imageSize: CGSize(width: 10, height: 10), boxRect: box, placement: p) == box)
    }
}
