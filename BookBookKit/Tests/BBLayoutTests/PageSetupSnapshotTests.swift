import AppKit
import BBModel
import CoreGraphics
import SnapshotTesting
import Testing
@testable import BBLayout

/// Phase 7 risk: "crops are kept where possible" across extreme page-setup changes. One placed
/// image (zoomed, off-centre focal point marked by a black dot) in a full-bleed box, drawn on
/// Letter portrait, 10×8 landscape and 8×8, bleed off and on. The bitmap covers the bleed so
/// the box's growth into it shows. Plus the screen guides with bleed on (single and spread).
@MainActor
@Suite("Page setup snapshots")
struct PageSetupSnapshotTests {
    init() { LayoutFixtures.registerFonts() }

    static let imageRef = ImageRef(sha256: String(repeating: "7e", count: 32), contentType: "public.png")
    static let focal = NormalizedPoint(x: 0.7, y: 0.3)

    static let sizes: [(name: String, size: PointSize, orientation: Orientation)] = [
        ("letterPortrait", PointSize(width: 612, height: 792), .portrait),
        ("tenByEightLandscape", PointSize(width: 720, height: 576), .landscape),
        ("eightByEight", PointSize(width: 576, height: 576), .square),
    ]

    /// Four coloured quadrants with a black dot at `focal` (CG bitmaps are y-up).
    static func quadrantImage() -> CGImage {
        let w = 96, h = 64
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let colours: [(CGRect, CGColor)] = [
            (CGRect(x: 0, y: 32, width: 48, height: 32), CGColor(srgbRed: 0.90, green: 0.35, blue: 0.30, alpha: 1)),
            (CGRect(x: 48, y: 32, width: 48, height: 32), CGColor(srgbRed: 0.95, green: 0.80, blue: 0.25, alpha: 1)),
            (CGRect(x: 0, y: 0, width: 48, height: 32), CGColor(srgbRed: 0.25, green: 0.55, blue: 0.85, alpha: 1)),
            (CGRect(x: 48, y: 0, width: 48, height: 32), CGColor(srgbRed: 0.35, green: 0.70, blue: 0.40, alpha: 1)),
        ]
        for (rect, colour) in colours {
            ctx.setFillColor(colour)
            ctx.fill(rect)
        }
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        let fx = CGFloat(focal.x) * CGFloat(w), fy = CGFloat(1 - focal.y) * CGFloat(h)
        ctx.fillEllipse(in: CGRect(x: fx - 4, y: fy - 4, width: 8, height: 8))
        return ctx.makeImage()!
    }

    /// A book whose image box covers the top 60% of the page, full bleed on its top, leading
    /// and trailing edges, with the image placed at zoom 1.5 on `focal`.
    static func content(size: PointSize, orientation: Orientation, bleed: Bool) -> BookContent {
        var content = LayoutFixtures.content(imageRef: imageRef, imagePixels: PixelSize(width: 96, height: 64),
                                             trim: size)
        content.style.pageSetup = PageSetup(trimSize: size, orientation: orientation,
                                            margins: EdgeInsetsPt(all: 36), bleedEnabled: bleed)
        let templateID = LayoutFixtures.template.id
        content.templates[templateID]?.boxes[0].frame = NormalizedRect(x: 0, y: 0, width: 1, height: 0.6)
        content.templates[templateID]?.boxes[0].bleedEdges = [.top, .leading, .trailing]
        content.templates[templateID]?.boxes[0].cornerRadius = 0
        content.templates[templateID]?.boxes[1].frame = NormalizedRect(x: 0.1, y: 0.66, width: 0.8, height: 0.26)
        let pageID = content.book.pageOrder[0]
        content.pages[pageID]?.images[LayoutFixtures.imageBoxID]?.placement?.zoom = 1.5
        content.pages[pageID]?.images[LayoutFixtures.imageBoxID]?.placement?.center = focal
        return content
    }

    /// Renders the page into a bitmap covering the bleed rect (the trim when bleed is off).
    static func render(_ content: BookContent, page: Page, options: RenderOptions, scale: CGFloat = 0.5) -> NSImage {
        let geometry = PageGeometry.drawGeometry(for: page, in: content)
        let sheet = geometry.bleedRect
        let ctx = LayoutFixtures.flippedBitmap(size: sheet.size, scale: scale)
        // A grey ground, so any part of the sheet the renderer leaves unpainted would show.
        ctx.setFillColor(CGColor(srgbRed: 0.8, green: 0.8, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: sheet.size))
        ctx.translateBy(x: -sheet.minX, y: -sheet.minY)
        PageRenderer(images: DictionaryImageSource([imageRef: quadrantImage()]))
            .draw(page: page, in: content, into: ctx, options: options)
        return NSImage(cgImage: ctx.makeImage()!, size: sheet.size)
    }

    @Test(arguments: [false, true])
    func placedImageAcrossSizeChanges(bleed: Bool) {
        for entry in Self.sizes {
            let content = Self.content(size: entry.size, orientation: entry.orientation, bleed: bleed)
            let image = Self.render(content, page: content.storyPages[0], options: .pdf)
            assertSnapshot(of: image, as: .image(precision: 0.99, perceptualPrecision: 0.97),
                           named: "\(entry.name)-bleed\(bleed ? "On" : "Off")")
        }
    }

    @Test func guidesWithBleedOn() {
        let content = Self.content(size: PointSize(width: 576, height: 576), orientation: .square, bleed: true)
        let image = Self.render(content, page: content.storyPages[0], options: .screen, scale: 1)
        assertSnapshot(of: image, as: .image(precision: 0.99, perceptualPrecision: 0.97))
    }

    @Test func spreadGuidesWithBleedOn() {
        // A spread: one full-bleed image per half (no bleed at the fold) and one safe area each.
        var content = Self.content(size: PointSize(width: 300, height: 300), orientation: .square, bleed: true)
        let left = BoxID("00000000-0000-0000-0000-0000000000C1"), right = BoxID("00000000-0000-0000-0000-0000000000C2")
        let spread = Template(id: TemplateID("00000000-0000-0000-0000-0000000000A9"), name: "Spread", kind: .spread,
                              boxes: [
                                  Box(id: left, frame: NormalizedRect(x: 0, y: 0, width: 0.5, height: 1),
                                      bleedEdges: .all, content: .image),
                                  Box(id: right, frame: NormalizedRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5),
                                      bleedEdges: .all, content: .image),
                              ])
        content.templates[spread.id] = spread
        let pageID = content.book.pageOrder[0]
        content.pages[pageID]?.templateID = spread.id
        content.pages[pageID]?.images = [:]
        let page = content.pages[pageID]!
        let image = Self.render(content, page: page, options: .screen, scale: 1)
        assertSnapshot(of: image, as: .image(precision: 0.99, perceptualPrecision: 0.97))
    }
}
