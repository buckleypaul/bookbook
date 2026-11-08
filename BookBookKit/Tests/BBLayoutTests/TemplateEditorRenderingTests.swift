import AppKit
import BBModel
import CoreGraphics
import SnapshotTesting
import Testing
@testable import BBLayout

@MainActor
@Suite("Template editor rendering")
struct TemplateEditorRenderingTests {
    init() { LayoutFixtures.registerFonts() }

    static let imageRef = ImageRef(sha256: String(repeating: "cd", count: 32), contentType: "public.png")

    // MARK: Text-box overrides

    static let sample = RichText(plain: "The quick brown fox jumps over the lazy dog and keeps running far away.")

    @Test func fontSizeOverrideChangesLayout() {
        let base = LayoutFixtures.typography
        let size = CGSize(width: 200, height: 400)
        let plain = TextBoxLayout(text: Self.sample, typography: base.applying(TextBoxStyle()), containerSize: size)
        let big = TextBoxLayout(text: Self.sample, typography: base.applying(TextBoxStyle(fontSize: 30)), containerSize: size)
        #expect(big.usedHeight > plain.usedHeight * 1.5)
        // nil overrides keep the existing behaviour.
        let direct = TextBoxLayout(text: Self.sample, typography: base, containerSize: size)
        #expect(direct.usedHeight == plain.usedHeight)
        #expect(base.applying(TextBoxStyle(padding: 4)) == base)
    }

    @Test func alignmentAndColourPrecedence() {
        let base = LayoutFixtures.typography
        let red = RGBA(red: 1, green: 0, blue: 0)
        let blue = RGBA(red: 0, green: 0, blue: 1)
        let style = TextBoxStyle(alignment: .center, color: red)
        let typography = base.applying(style)
        #expect(typography.alignment == .center && typography.color == red)

        let text = RichText(paragraphs: [
            Paragraph(runs: [Run(text: "Box style")]),
            Paragraph(runs: [Run(text: "Run colour", color: blue)], alignment: .trailing),
        ])
        let attributed = RichTextBridge.attributedString(from: text, typography: typography)
        func color(at index: Int) -> NSColor? { attributed.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor }
        func alignment(at index: Int) -> NSTextAlignment? {
            (attributed.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle)?.alignment
        }
        #expect(RichTextBridge.rgba(color(at: 0)!) == red)               // box > style guide
        #expect(RichTextBridge.rgba(color(at: attributed.length - 1)!) == blue)   // run > box
        #expect(alignment(at: 0) == .center)                              // box > style guide
        #expect(alignment(at: attributed.length - 1) == .right)           // paragraph > box
        // Round trip: the box defaults read back as no override.
        #expect(RichTextBridge.richText(from: attributed, typography: typography) == text)
    }

    @Test func rendererAppliesBoxOverrides() {
        func darkPixels(style: TextBoxStyle) -> (total: Int, leftHalf: Int) {
            let ref = Self.imageRef
            var content = LayoutFixtures.content(imageRef: ref, imagePixels: PixelSize(width: 8, height: 8),
                                                 text: RichText(plain: "Hi"))
            var template = content.template(for: content.storyPages[0])!
            template.boxes = template.boxes.map { box in
                var box = box
                if case .text = box.content { box.content = .text(style) }
                return box
            }
            content.templates[template.id] = template
            let size = PageGeometry(setup: content.style.pageSetup).trimSize
            let ctx = LayoutFixtures.flippedBitmap(size: size, scale: 1)
            PageRenderer(images: DictionaryImageSource()).draw(page: content.storyPages[0], in: content, into: ctx, options: .pdf)
            let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
            var total = 0, left = 0
            for row in 186..<290 {
                for col in 0..<300 where data[row * ctx.bytesPerRow + col * 4] < 100 {
                    total += 1
                    if col < 150 { left += 1 }
                }
            }
            return (total, left)
        }
        let plain = darkPixels(style: TextBoxStyle())
        let big = darkPixels(style: TextBoxStyle(fontSize: 40))
        let centred = darkPixels(style: TextBoxStyle(alignment: .center))
        let white = darkPixels(style: TextBoxStyle(color: .white))
        #expect(plain.total > 0 && plain.leftHalf == plain.total)   // leading-aligned, in the left half
        #expect(big.total > plain.total * 3)
        #expect(centred.leftHalf < centred.total)                   // centred text crosses the middle
        #expect(white.total == 0)
    }

    // MARK: Preview sample content

    func previewContent() -> BookContent {
        var content = LayoutFixtures.content(imageRef: Self.imageRef, imagePixels: PixelSize(width: 8, height: 8))
        var page = content.storyPages[0]
        page.text = [:]
        page.images[LayoutFixtures.imageBoxID]?.placement = nil
        content.pages[page.id] = page
        return content
    }

    func render(_ content: BookContent, options: RenderOptions, source: DictionaryImageSource = DictionaryImageSource()) -> (NSImage, CGContext) {
        let size = PageGeometry(setup: content.style.pageSetup).trimSize
        let ctx = LayoutFixtures.flippedBitmap(size: size, scale: 2)
        PageRenderer(images: source).draw(page: content.storyPages[0], in: content, into: ctx, options: options)
        return (NSImage(cgImage: ctx.makeImage()!, size: size), ctx)
    }

    @Test func previewSampleContentSnapshot() {
        let options = RenderOptions(target: .screen, previewSampleContent: true)
        assertSnapshot(of: render(previewContent(), options: options).0,
                       as: .image(precision: 0.99, perceptualPrecision: 0.97))
    }

    @Test func previewOffDrawsNothingForEmptyBoxes() {
        let (_, ctx) = render(previewContent(), options: RenderOptions(target: .pdfTrim))
        let off = ctx.makeImage()!
        let (_, ctx2) = render(previewContent(), options: RenderOptions(target: .pdfTrim, previewSampleContent: true))
        #expect(off.dataProvider!.data != ctx2.makeImage()!.dataProvider!.data)
        // With the preview off the page stays the box panel on white: no dark text pixels.
        let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
        var dark = 0
        for row in 0..<ctx.height { for col in 0..<ctx.width where data[row * ctx.bytesPerRow + col * 4] < 100 { dark += 1 } }
        #expect(dark == 0)
    }

    // MARK: Rotated, rounded image box

    func rotatedContent(rotation: Double) -> BookContent {
        var content = LayoutFixtures.content(imageRef: Self.imageRef, imagePixels: PixelSize(width: 64, height: 32))
        var template = content.template(for: content.storyPages[0])!
        template.boxes = [Box(id: LayoutFixtures.imageBoxID, frame: NormalizedRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6),
                              rotationDegrees: rotation, cornerRadius: 30, content: .image)]
        content.templates[template.id] = template
        return content
    }

    @Test func rotatedRoundedImageBoxSnapshot() {
        let image = LayoutFixtures.solidImage(width: 64, height: 32, red: 0.15, green: 0.55, blue: 0.6)
        let (rendered, _) = render(rotatedContent(rotation: 5), options: .pdf, source: DictionaryImageSource([Self.imageRef: image]))
        assertSnapshot(of: rendered, as: .image(precision: 0.99, perceptualPrecision: 0.97))
    }

    @Test func rotatedImageIsClippedToRotatedRoundedRect() {
        let image = LayoutFixtures.solidImage(width: 64, height: 32, red: 0, green: 0, blue: 0)
        func isInk(_ ctx: CGContext, _ x: CGFloat, _ y: CGFloat) -> Bool {
            let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
            return data[Int(y * 2) * ctx.bytesPerRow + Int(x * 2) * 4] < 128
        }
        let source = DictionaryImageSource([Self.imageRef: image])
        for options in [RenderOptions.pdf, RenderOptions(target: .screen)] {
            let (_, ctx) = render(rotatedContent(rotation: 5), options: options, source: source)
            // Box: x 60...240, y 60...240, radius 30, rotated 5 degrees clockwise about (150,150).
            #expect(isInk(ctx, 150, 150))
            // The unrotated corner point lies outside the rounded corner: not painted.
            #expect(!isInk(ctx, 63, 63))
            #expect(!isInk(ctx, 237, 237))
            // A point just inside the rotated top edge (top edge descends to the right of centre
            // for clockwise rotation) is painted; the same height beyond the other end is not.
            #expect(isInk(ctx, 150, 63))
            #expect(!isInk(ctx, 150, 57))
            // Right of centre the rotated top edge has moved down (clockwise), so the
            // unrotated top-edge line at x=200 is outside; on the left it has moved up.
            #expect(!isInk(ctx, 200, 61))
            #expect(isInk(ctx, 100, 61))
        }
    }
}
