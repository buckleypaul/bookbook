import AppKit
import BBModel
import CoreGraphics
import Foundation
import SnapshotTesting
import Testing
@testable import BBLayout

/// The same text box drawn on screen (bitmap) and into a PDF that is then rasterised must match.
@MainActor
@Suite("Screen vs PDF text")
struct ScreenVersusPDFTests {
    init() { LayoutFixtures.registerFonts() }

    static let imageRef = ImageRef(sha256: String(repeating: "ef", count: 32), contentType: "public.png")
    static let scale: CGFloat = 2

    static let text = RichText(paragraphs: [
        Paragraph(runs: [
            Run(text: "Once upon a "), Run(text: "time", italic: true), Run(text: ", a fox cried "),
            Run(text: "BOOM!", bold: true, size: 20, color: RGBA(red: 0.85, green: 0.1, blue: 0.1)),
        ]),
        Paragraph(runs: [Run(text: "Underlined and centred.", underline: true)], alignment: .center),
    ])

    func content() -> BookContent {
        LayoutFixtures.content(imageRef: Self.imageRef, imagePixels: PixelSize(width: 8, height: 8), text: Self.text)
    }

    func renderer() -> PageRenderer {
        PageRenderer(images: DictionaryImageSource([Self.imageRef:
            LayoutFixtures.solidImage(width: 8, height: 8, red: 0.15, green: 0.55, blue: 0.6)]))
    }

    func screenBitmap() -> CGImage {
        let content = content()
        let size = PageGeometry(setup: content.style.pageSetup).trimSize
        let ctx = LayoutFixtures.flippedBitmap(size: size, scale: Self.scale)
        renderer().draw(page: content.storyPages[0], in: content, into: ctx, options: RenderOptions(target: .screen))
        return ctx.makeImage()!
    }

    func pdfRasterised() throws -> CGImage {
        let content = content()
        let size = PageGeometry(setup: content.style.pageSetup).trimSize
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: size)
        let consumer = try #require(CGDataConsumer(data: data))
        let pdf = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        pdf.beginPDFPage(nil)
        pdf.translateBy(x: 0, y: size.height)
        pdf.scaleBy(x: 1, y: -1)
        renderer().draw(page: content.storyPages[0], in: content, into: pdf, options: RenderOptions(target: .pdfTrim))
        pdf.endPDFPage()
        pdf.closePDF()

        let provider = try #require(CGDataProvider(data: data as CFData))
        let page = try #require(CGPDFDocument(provider)?.page(at: 1))
        let w = Int(size.width * Self.scale), h = Int(size.height * Self.scale)
        let ctx = try #require(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: Self.scale, y: Self.scale)
        ctx.drawPDFPage(page)
        return try #require(ctx.makeImage())
    }

    /// Greyscale bytes of the text box region (page y 0.62...0.94 of 300 pt).
    func textRegion(_ image: CGImage) -> [UInt8] {
        let rect = CGRect(x: 24 * Self.scale, y: 186 * Self.scale, width: 252 * Self.scale, height: 96 * Self.scale)
        let cropped = image.cropping(to: rect)!
        let ctx = CGContext(data: nil, width: cropped.width, height: cropped.height, bitsPerComponent: 8,
                            bytesPerRow: cropped.width, space: CGColorSpaceCreateDeviceGray(),
                            bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height))
        let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: data, count: cropped.width * cropped.height))
    }

    @Test func sameBoxOnScreenAndInPDFMatches() throws {
        let screen = textRegion(screenBitmap())
        let pdf = textRegion(try pdfRasterised())
        #expect(screen.count == pdf.count)
        // Both must contain ink (not blank), and the ink coverage must agree closely.
        func ink(_ px: [UInt8]) -> Double { px.reduce(0) { $0 + Double(255 - Int($1)) } / 255 }
        let screenInk = ink(screen), pdfInk = ink(pdf)
        #expect(screenInk > 200)
        #expect(abs(screenInk - pdfInk) / screenInk < 0.08)
        // Mean absolute pixel difference stays small (anti-aliasing differences only).
        let diff = zip(screen, pdf).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(screen.count)
        #expect(diff < 6)
    }

    @Test func screenSnapshot() {
        let size = PageGeometry(setup: content().style.pageSetup).trimSize
        assertSnapshot(of: NSImage(cgImage: screenBitmap(), size: size),
                       as: .image(precision: 0.99, perceptualPrecision: 0.97))
    }

    @Test func titleRoleBoxRendersWithTitleFont() {
        var titled = content()
        var template = titled.template(for: titled.storyPages[0])!
        template.boxes = template.boxes.map { box in
            var copy = box
            if case .text = copy.content { copy.role = .title }
            return copy
        }
        titled.templates[template.id] = template
        let size = PageGeometry(setup: titled.style.pageSetup).trimSize
        func render(_ c: BookContent) -> [UInt8] {
            let ctx = LayoutFixtures.flippedBitmap(size: size, scale: Self.scale)
            renderer().draw(page: c.storyPages[0], in: c, into: ctx, options: RenderOptions(target: .pdfTrim))
            return textRegion(ctx.makeImage()!)
        }
        // Title font is Bold, body is Regular: the pixels must differ.
        #expect(render(titled) != render(content()))
    }
}
