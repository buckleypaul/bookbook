import BBModel
import CoreGraphics
import Foundation

/// One renderer for screen, thumbnails and PDF (A §8.4, D8). Draw order: background, image
/// boxes in layer order (clipped, placement transform), text boxes (panel then text),
/// page numbers, screen-only guides.
@MainActor
public struct PageRenderer {
    /// Fill for empty image boxes when `showEmptyImagePlaceholders` is on.
    static let placeholderFill = CGColor(srgbRed: 0.93, green: 0.93, blue: 0.94, alpha: 1)
    static let placeholderStroke = CGColor(srgbRed: 0.80, green: 0.80, blue: 0.82, alpha: 1)
    static let safeAreaGuide = CGColor(srgbRed: 0.20, green: 0.55, blue: 0.95, alpha: 0.6)
    static let boxGuide = CGColor(srgbRed: 0.55, green: 0.55, blue: 0.60, alpha: 0.6)
    /// The trim line, drawn when bleed is on.
    static let trimGuide = CGColor(srgbRed: 0.90, green: 0.20, blue: 0.20, alpha: 0.75)

    public var images: any PageImageSource
    /// Optional layout cache (the canvas sets it). When nil, every draw lays out afresh.
    public var layouts: TextBoxLayoutCache?
    /// Export-time bitmaps (Phase 14, A §8.4 / §9.1). When set and it has an image for a box,
    /// that image fills the box's render rect (clipped to the box shape) with no placement
    /// transform, so the renderer never resamples; otherwise the box draws from `images`.
    public var prepared: (any PreparedImageSource)?

    public init(images: any PageImageSource) {
        self.images = images
    }

    /// Draws `page` into `ctx`. The caller sets up `ctx` so its user space is the page's trim in
    /// points (double width for a spread: `PageGeometry(setup:kind:)`), origin top-left, y down (e.g. a flipped NSView, or a PDF context after
    /// `translateBy(0, h); scaleBy(1, -1)`). Missing templates or images draw nothing / a placeholder.
    public func draw(page: Page, in content: BookContent, into ctx: CGContext, options: RenderOptions) {
        draw(page: page, in: content, into: ctx, options: options, visibleRect: nil)
    }

    /// Same, but skips boxes whose (rotated) bounds miss `visibleRect` (trim space), so a
    /// spread exported as two single PDF pages doesn't carry the other half's text in each
    /// page's content stream. The caller clips to `visibleRect`; `nil` draws every box.
    public func draw(page: Page, in content: BookContent, into ctx: CGContext, options: RenderOptions,
                     visibleRect: CGRect?) {
        let template = content.template(for: page)
        let geometry = PageGeometry(setup: content.style.pageSetup, kind: template?.kind)
        ctx.saveGState()
        defer { ctx.restoreGState() }

        // 1. Background (covers the bleed too, for when the context shows it).
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(geometry.bleedRect)

        guard let template else { return }

        func isVisible(_ box: Box) -> Bool {
            guard let visibleRect else { return true }
            return Self.bounds(of: box, geometry: geometry).intersects(visibleRect)
        }

        // 2. Image boxes, in layer order.
        for box in template.boxes where box.content == .image && isVisible(box) {
            drawImageBox(box, page: page, content: content, geometry: geometry, ctx: ctx, options: options)
        }

        // 3. Text boxes: panel, then text.
        let typography = content.style.typography
        for box in template.boxes {
            guard case .text(let style) = box.content, !options.hiddenTextBoxes.contains(box.id), isVisible(box)
            else { continue }
            var text = CoverText.boundText(for: box.role, book: content.book) ?? page.text[box.id]
            if options.previewSampleContent, text?.paragraphs.isEmpty ?? true {
                text = Self.sampleText
            }
            drawTextBox(box, style: style, text: text, typography: typography, geometry: geometry, ctx: ctx)
        }

        // 4. Page numbers.
        for mark in options.pageNumbers {
            PageNumberDrawing.draw(mark, content: content, template: template, geometry: geometry,
                                   layouts: layouts, ctx: ctx)
        }

        // 5. Guides, on screen only.
        if options.showGuides, options.target == .screen {
            drawGuides(template: template, geometry: geometry, ctx: ctx)
        }
    }

    /// True if any text box on the page overflows.
    public func overflowingTextBoxes(page: Page, in content: BookContent) -> Set<BoxID> {
        guard let template = content.template(for: page) else { return [] }
        let geometry = PageGeometry(setup: content.style.pageSetup, kind: template.kind)
        var result: Set<BoxID> = []
        for box in template.boxes {
            guard case .text(let style) = box.content,
                  let text = CoverText.boundText(for: box.role, book: content.book) ?? page.text[box.id],
                  !text.paragraphs.isEmpty
            else { continue }
            let rect = Self.textRect(box, style: style, geometry: geometry)
            let size = CGSize(width: max(0, rect.width), height: max(0, rect.height))
            let layout = textLayout(text, box: box, style: style, typography: content.style.typography, size: size)
            if layout.isOverflowing { result.insert(box.id) }
        }
        return result
    }

    // MARK: Boxes

    private func drawImageBox(_ box: Box, page: Page, content: BookContent, geometry: PageGeometry,
                              ctx: CGContext, options: RenderOptions) {
        let rect = geometry.renderRect(for: box)
        guard rect.width > 0, rect.height > 0 else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        applyRotation(box, rect: rect, ctx: ctx)
        let path = boxPath(rect, cornerRadius: box.cornerRadius)
        let isOutput = options.target == .pdfBleed || options.target == .print

        if let prepared, let image = prepared.preparedImage(for: BoxImageKey(page: page.id, box: box.id)) {
            ctx.addPath(path)
            ctx.clip()
            // Already cropped and resampled to the render rect: draw it filling the rect (flip locally).
            ctx.translateBy(x: rect.minX, y: rect.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
        } else if let slot = page.images[box.id], let placement = slot.placement,
           let version = content.placedVersion(page: page.id, box: box.id),
           let image = images.image(for: version.image) {
            ctx.addPath(path)
            ctx.clip()
            let imageSize = CGSize(width: image.width, height: image.height)
            let target = PageGeometry.imageRect(imageSize: imageSize, boxRect: rect, placement: placement)
            // The context is y-down; CGContext.draw(image:) assumes y-up, so flip locally.
            ctx.translateBy(x: target.minX, y: target.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(origin: .zero, size: target.size))
        } else if isOutput {
            // Print and bleed PDFs never draw editor placeholders or sample art.
            return
        } else if options.previewSampleContent, page.images[box.id]?.placement == nil {
            ctx.addPath(path)
            ctx.clip()
            Self.drawSampleArt(in: rect, ctx: ctx)
        } else if options.showEmptyImagePlaceholders {
            ctx.addPath(path)
            ctx.setFillColor(Self.placeholderFill)
            ctx.fillPath()
            ctx.addPath(path)
            ctx.setStrokeColor(Self.placeholderStroke)
            ctx.setLineWidth(1)
            ctx.strokePath()
        }
    }

    /// The rect a text box's text is laid out in: its render rect inset by the padding.
    private static func textRect(_ box: Box, style: TextBoxStyle, geometry: PageGeometry) -> CGRect {
        geometry.renderRect(for: box).insetBy(dx: CGFloat(style.padding), dy: CGFloat(style.padding))
    }

    /// The text box's layout at `size`, with the book typography resolved for the box's role and
    /// style, from `layouts` when set. Shared by drawing and overflow checks so they agree.
    private func textLayout(_ text: RichText, box: Box, style: TextBoxStyle, typography: Typography,
                            size: CGSize) -> TextBoxLayout {
        let resolved = typography.resolved(for: box.role).applying(style)
        return layouts?.layout(text: text, typography: resolved, containerSize: size)
            ?? TextBoxLayout(text: text, typography: resolved, containerSize: size)
    }

    /// `typography` is the book's, unresolved.
    private func drawTextBox(_ box: Box, style: TextBoxStyle, text: RichText?, typography: Typography,
                             geometry: PageGeometry, ctx: CGContext) {
        let rect = geometry.renderRect(for: box)
        guard rect.width > 0, rect.height > 0 else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        applyRotation(box, rect: rect, ctx: ctx)

        if let background = style.background {
            ctx.addPath(boxPath(rect, cornerRadius: box.cornerRadius))
            ctx.setFillColor(CGColor(srgbRed: background.red, green: background.green,
                                     blue: background.blue, alpha: background.alpha))
            ctx.fillPath()
        }
        guard let text, !text.paragraphs.isEmpty else { return }
        let inner = Self.textRect(box, style: style, geometry: geometry)
        guard inner.width > 0, inner.height > 0 else { return }
        textLayout(text, box: box, style: style, typography: typography, size: inner.size)
            .draw(in: ctx, origin: inner.origin)
    }

    /// Screen-only overlays (A §8.4 step 5): the trim line when bleed is on (the area outside
    /// it is the bleed), each page's safe area (two on a spread, with the margins on both
    /// sides of the fold), and every box's outline. Never drawn into an export.
    private func drawGuides(template: Template, geometry: PageGeometry, ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setLineWidth(0.75)
        if geometry.bleed > 0 {
            ctx.setStrokeColor(Self.trimGuide)
            ctx.stroke(geometry.trimRect)
        }
        ctx.setLineDash(phase: 0, lengths: [4, 3])
        ctx.setStrokeColor(Self.safeAreaGuide)
        for area in geometry.pageSafeAreas { ctx.stroke(area) }
        ctx.setStrokeColor(Self.boxGuide)
        for box in template.boxes {
            let rect = geometry.renderRect(for: box)
            ctx.saveGState()
            applyRotation(box, rect: rect, ctx: ctx)
            ctx.addPath(boxPath(rect, cornerRadius: box.cornerRadius))
            ctx.strokePath()
            ctx.restoreGState()
        }
    }

    // MARK: Template-editor preview

    /// Sample text drawn in empty text boxes when `previewSampleContent` is on.
    static let sampleText = RichText(plain: "Once upon a time, in a small house at the edge of a quiet wood, a curious fox found a red scarf and set off to see the world.")

    /// A soft gradient with a simple landscape glyph, filling `rect` (the caller has clipped).
    static func drawSampleArt(in rect: CGRect, ctx: CGContext) {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let colors = [CGColor(srgbRed: 0.80, green: 0.89, blue: 0.96, alpha: 1),
                      CGColor(srgbRed: 0.97, green: 0.92, blue: 0.84, alpha: 1)] as CFArray
        if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: rect.minY),
                                   end: CGPoint(x: rect.minX, y: rect.maxY), options: [])
        }
        let side = min(rect.width, rect.height)
        guard side > 8 else { return }
        let glyph = CGRect(x: rect.midX - side * 0.3, y: rect.midY - side * 0.2, width: side * 0.6, height: side * 0.4)
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.7))
        let sun = side * 0.07
        ctx.fillEllipse(in: CGRect(x: glyph.maxX - sun * 3, y: glyph.minY, width: sun * 2, height: sun * 2))
        let mountains = CGMutablePath()
        mountains.move(to: CGPoint(x: glyph.minX, y: glyph.maxY))
        mountains.addLine(to: CGPoint(x: glyph.minX + glyph.width * 0.32, y: glyph.minY + glyph.height * 0.3))
        mountains.addLine(to: CGPoint(x: glyph.minX + glyph.width * 0.55, y: glyph.minY + glyph.height * 0.65))
        mountains.addLine(to: CGPoint(x: glyph.minX + glyph.width * 0.7, y: glyph.minY + glyph.height * 0.45))
        mountains.addLine(to: CGPoint(x: glyph.maxX, y: glyph.maxY))
        mountains.closeSubpath()
        ctx.addPath(mountains)
        ctx.fillPath()
    }

    // MARK: Helpers

    /// The box's render rect, grown to cover its rotation (about the render rect's centre, see
    /// `PageGeometry.renderRect(for:)`).
    static func bounds(of box: Box, geometry: PageGeometry) -> CGRect {
        let rect = geometry.renderRect(for: box)
        guard box.rotationDegrees != 0, box.rotationDegrees.isFinite else { return rect }
        let transform = CGAffineTransform(translationX: rect.midX, y: rect.midY)
            .rotated(by: CGFloat(box.rotationDegrees) * .pi / 180)
            .translatedBy(x: -rect.midX, y: -rect.midY)
        return rect.applying(transform)
    }

    /// Rotates the context around the centre of the box's RENDER rect (bleed-extended when bleed
    /// is on; clockwise on the page for positive degrees). The editors outline and hit-test
    /// about the same centre (`PageGeometry.renderRect(for:)`).
    private func applyRotation(_ box: Box, rect: CGRect, ctx: CGContext) {
        guard box.rotationDegrees != 0, box.rotationDegrees.isFinite else { return }
        ctx.translateBy(x: rect.midX, y: rect.midY)
        ctx.rotate(by: CGFloat(box.rotationDegrees) * .pi / 180)
        ctx.translateBy(x: -rect.midX, y: -rect.midY)
    }

    private func boxPath(_ rect: CGRect, cornerRadius: Double) -> CGPath {
        let radius = min(CGFloat(max(0, cornerRadius)), rect.width / 2, rect.height / 2)
        guard radius > 0 else { return CGPath(rect: rect, transform: nil) }
        return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }
}
