import BBModel
import CoreGraphics
import Testing
@testable import BBLayout

/// Phase 14: `PageRenderer.prepared` (A §8.4 / §9.1) and the `.pdfBleed` / `.print` targets.
@MainActor
@Suite("PageRenderer prepared images")
struct PreparedImageRenderingTests {
    init() { LayoutFixtures.registerFonts() }

    static let imageRef = ImageRef(sha256: String(repeating: "ef", count: 32), contentType: "public.png")

    final class Prepared: PreparedImageSource {
        var images: [BoxImageKey: CGImage]
        var asked: [BoxImageKey] = []
        init(_ images: [BoxImageKey: CGImage]) { self.images = images }
        func preparedImage(for key: BoxImageKey) -> CGImage? {
            asked.append(key)
            return images[key]
        }
    }

    func pixel(_ ctx: CGContext, _ x: Int, _ y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
        let i = y * ctx.bytesPerRow + x * 4
        return (data[i], data[i + 1], data[i + 2])
    }

    @Test func preparedImageFillsBoxInsteadOfSource() throws {
        let content = LayoutFixtures.content(imageRef: Self.imageRef, imagePixels: PixelSize(width: 64, height: 32))
        let page = content.storyPages[0]
        // Source is red; the prepared bitmap is green with a blue top-left quadrant.
        let source = LayoutFixtures.solidImage(width: 64, height: 32, red: 1, green: 0, blue: 0)
        let bitmap = CGContext(data: nil, width: 40, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        bitmap.setFillColor(CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        bitmap.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 20, width: 20, height: 20)) // y-up: top-left quadrant
        let key = BoxImageKey(page: page.id, box: LayoutFixtures.imageBoxID)
        let prepared = Prepared([key: bitmap.makeImage()!])

        let size = PageGeometry(setup: content.style.pageSetup).trimSize
        let ctx = LayoutFixtures.flippedBitmap(size: size, scale: 1)
        var renderer = PageRenderer(images: DictionaryImageSource([Self.imageRef: source]))
        renderer.prepared = prepared
        renderer.draw(page: page, in: content, into: ctx, options: .pdf)

        #expect(prepared.asked == [key])
        // Box: x 24…276, y 18…174. Top-left quadrant of the box is blue, the rest green, no red.
        let topLeft = pixel(ctx, 60, 50)
        #expect(topLeft.b > 200 && topLeft.r < 30 && topLeft.g < 30)
        let bottomRight = pixel(ctx, 240, 150)
        #expect(bottomRight.g > 200 && bottomRight.r < 30)
        // Outside the box stays white (the image fills exactly the render rect).
        let outside = pixel(ctx, 10, 10)
        #expect(outside.r > 250 && outside.g > 250 && outside.b > 250)
    }

    @Test func missingPreparedImageFallsBackToSource() {
        let content = LayoutFixtures.content(imageRef: Self.imageRef, imagePixels: PixelSize(width: 64, height: 32))
        let source = LayoutFixtures.solidImage(width: 64, height: 32, red: 1, green: 0, blue: 0)
        let size = PageGeometry(setup: content.style.pageSetup).trimSize
        let ctx = LayoutFixtures.flippedBitmap(size: size, scale: 1)
        var renderer = PageRenderer(images: DictionaryImageSource([Self.imageRef: source]))
        renderer.prepared = Prepared([:])
        renderer.draw(page: content.storyPages[0], in: content, into: ctx, options: .pdf)
        let p = pixel(ctx, 150, 100)
        #expect(p.r > 200 && p.g < 30)
    }

    @Test func outputTargetsDrawNoPlaceholdersOrGuides() {
        // No image available: screen options draw a grey placeholder; print/bleed never do.
        let content = LayoutFixtures.content(imageRef: Self.imageRef, imagePixels: PixelSize(width: 64, height: 32))
        let size = PageGeometry(setup: content.style.pageSetup).trimSize
        for target in [RenderOptions.Target.print, .pdfBleed] {
            let ctx = LayoutFixtures.flippedBitmap(size: size, scale: 1)
            let options = RenderOptions(target: target, showGuides: true, showEmptyImagePlaceholders: true)
            PageRenderer(images: DictionaryImageSource()).draw(page: content.storyPages[0], in: content,
                                                               into: ctx, options: options)
            let p = pixel(ctx, 150, 100)
            #expect(p.r > 250 && p.g > 250 && p.b > 250, "target \(target)")
        }
    }

    @Test func pdfBleedDrawsPastTheTrim() {
        // A full-bleed image box with bleed on: content reaches into the bleed (negative coordinates).
        var content = LayoutFixtures.content(imageRef: Self.imageRef, imagePixels: PixelSize(width: 64, height: 32))
        content.style.pageSetup.bleedEnabled = true
        content.style.pageSetup.bleedAmount = 9
        var template = LayoutFixtures.template
        template.boxes[0].frame = NormalizedRect(x: 0, y: 0, width: 1, height: 0.5)
        template.boxes[0].bleedEdges = [.top, .leading, .trailing]
        content.templates[template.id] = template
        let source = LayoutFixtures.solidImage(width: 64, height: 32, red: 1, green: 0, blue: 0)
        let size = CGSize(width: 318, height: 318)
        let ctx = LayoutFixtures.flippedBitmap(size: size, scale: 1)
        ctx.translateBy(x: 9, y: 9) // trim origin inside the bleed area
        PageRenderer(images: DictionaryImageSource([Self.imageRef: source]))
            .draw(page: content.storyPages[0], in: content, into: ctx, options: RenderOptions(target: .pdfBleed))
        let corner = pixel(ctx, 3, 3) // inside the bleed, outside the trim
        #expect(corner.r > 200 && corner.g < 30)
    }
}
