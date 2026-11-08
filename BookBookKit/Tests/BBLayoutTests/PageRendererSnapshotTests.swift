import AppKit
import BBModel
import CoreGraphics
import SnapshotTesting
import Testing
@testable import BBLayout

@MainActor
@Suite("PageRenderer snapshots")
struct PageRendererSnapshotTests {
    init() { LayoutFixtures.registerFonts() }

    static let imageRef = ImageRef(sha256: String(repeating: "ab", count: 32), contentType: "public.png")

    func render(options: RenderOptions, scale: CGFloat = 2) -> NSImage {
        // A wide teal image in a near-square box: aspect-fill crops its sides.
        let image = LayoutFixtures.solidImage(width: 64, height: 32, red: 0.15, green: 0.55, blue: 0.6)
        let content = LayoutFixtures.content(imageRef: Self.imageRef, imagePixels: PixelSize(width: 64, height: 32))
        let size = PageGeometry(setup: content.style.pageSetup).trimSize
        let ctx = LayoutFixtures.flippedBitmap(size: size, scale: scale)
        PageRenderer(images: DictionaryImageSource([Self.imageRef: image]))
            .draw(page: content.storyPages[0], in: content, into: ctx, options: options)
        return NSImage(cgImage: ctx.makeImage()!, size: size)
    }

    @Test func pdfOptions_imageAndTwoSentences() {
        assertSnapshot(of: render(options: .pdf), as: .image(precision: 0.99, perceptualPrecision: 0.97))
    }

    @Test func screenOptions_guidesAndPlaceholder() {
        // Screen options with an image source that can't find the image: placeholder plus guides.
        let content = LayoutFixtures.content(imageRef: Self.imageRef, imagePixels: PixelSize(width: 64, height: 32))
        let size = PageGeometry(setup: content.style.pageSetup).trimSize
        let ctx = LayoutFixtures.flippedBitmap(size: size, scale: 2)
        PageRenderer(images: DictionaryImageSource())
            .draw(page: content.storyPages[0], in: content, into: ctx, options: .screen)
        let image = NSImage(cgImage: ctx.makeImage()!, size: size)
        assertSnapshot(of: image, as: .image(precision: 0.99, perceptualPrecision: 0.97))
    }

    @Test func imageIsDrawnUpright() {
        // Top half red, bottom half blue (CG bitmap contexts are y-up, so the top is y ≥ h/2).
        let bitmap = CGContext(data: nil, width: 20, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        bitmap.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 10, width: 20, height: 10))
        bitmap.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: 20, height: 10))
        let image = bitmap.makeImage()!
        let content = LayoutFixtures.content(imageRef: Self.imageRef, imagePixels: PixelSize(width: 20, height: 20))
        let size = PageGeometry(setup: content.style.pageSetup).trimSize
        let ctx = LayoutFixtures.flippedBitmap(size: size, scale: 1)
        PageRenderer(images: DictionaryImageSource([Self.imageRef: image]))
            .draw(page: content.storyPages[0], in: content, into: ctx, options: .pdf)
        let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
        func pixel(_ x: Int, _ y: Int) -> (r: UInt8, b: UInt8) {
            let i = y * ctx.bytesPerRow + x * 4
            return (data[i], data[i + 2])
        }
        // Image box spans y 18…174 pt on the 300 pt page; memory rows run top-down.
        #expect(pixel(150, 40).r > 200 && pixel(150, 40).b < 50)
        #expect(pixel(150, 160).b > 200 && pixel(150, 160).r < 50)
    }

    @Test func hiddenTextBoxIsNotDrawn() throws {
        let image = LayoutFixtures.solidImage(width: 8, height: 8, red: 0, green: 0, blue: 1)
        let content = LayoutFixtures.content(imageRef: Self.imageRef, imagePixels: PixelSize(width: 8, height: 8))
        let size = PageGeometry(setup: content.style.pageSetup).trimSize
        func inkInTextBox(_ options: RenderOptions) -> Int {
            let ctx = LayoutFixtures.flippedBitmap(size: size, scale: 1)
            PageRenderer(images: DictionaryImageSource([Self.imageRef: image]))
                .draw(page: content.storyPages[0], in: content, into: ctx, options: options)
            let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
            // Text box rows: y 0.62…0.94 of 300 pt (bitmap rows run top-down in memory).
            var dark = 0
            for row in 190..<280 {
                for col in 30..<270 where data[row * ctx.bytesPerRow + col * 4] < 100 { dark += 1 }
            }
            return dark
        }
        #expect(inkInTextBox(.pdf) > 200)
        #expect(inkInTextBox(RenderOptions(target: .pdfTrim, hiddenTextBoxes: [LayoutFixtures.textBoxID])) == 0)
    }
}
