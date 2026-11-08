import BBModel
import CoreGraphics
import Foundation

/// One renderer for screen, thumbnails and PDF (A §8.4, D8). Draw order: background, image
/// boxes in layer order (clipped, placement transform), text boxes (panel then text),
/// page number (Phase 5), screen-only guides.
@MainActor
public struct PageRenderer {
    /// Fill for empty image boxes when `showEmptyImagePlaceholders` is on.
    static let placeholderFill = CGColor(srgbRed: 0.93, green: 0.93, blue: 0.94, alpha: 1)
    static let placeholderStroke = CGColor(srgbRed: 0.80, green: 0.80, blue: 0.82, alpha: 1)
    static let safeAreaGuide = CGColor(srgbRed: 0.20, green: 0.55, blue: 0.95, alpha: 0.6)
    static let boxGuide = CGColor(srgbRed: 0.55, green: 0.55, blue: 0.60, alpha: 0.6)

    public var images: any PageImageSource

    public init(images: any PageImageSource) {
        self.images = images
    }

    /// Draws `page` into `ctx`. The caller sets up `ctx` so its user space is the page's trim in
    /// points, origin top-left, y down (e.g. a flipped NSView, or a PDF context after
    /// `translateBy(0, h); scaleBy(1, -1)`). Missing templates or images draw nothing / a placeholder.
    public func draw(page: Page, in content: BookContent, into ctx: CGContext, options: RenderOptions) {
        let geometry = PageGeometry(setup: content.style.pageSetup)
        ctx.saveGState()
        defer { ctx.restoreGState() }

        // 1. Background (covers the bleed too, for when the context shows it).
        let bleed = geometry.bleed
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(geometry.trimRect.insetBy(dx: -bleed, dy: -bleed))

        guard let template = content.template(for: page) else { return }

        // 2. Image boxes, in layer order.
        for box in template.boxes where box.content == .image {
            drawImageBox(box, page: page, content: content, geometry: geometry, ctx: ctx, options: options)
        }

        // 3. Text boxes: panel, then text.
        let typography = content.style.typography
        for box in template.boxes {
            guard case .text(let style) = box.content, !options.hiddenTextBoxes.contains(box.id) else { continue }
            drawTextBox(box, style: style, text: page.text[box.id], typography: typography,
                        geometry: geometry, ctx: ctx)
        }

        // 4. Page number: Phase 5.

        // 5. Guides, on screen only.
        if options.showGuides, options.target == .screen {
            drawGuides(template: template, geometry: geometry, ctx: ctx)
        }
    }

    /// True if any text box on the page overflows.
    public func overflowingTextBoxes(page: Page, in content: BookContent) -> Set<BoxID> {
        guard let template = content.template(for: page) else { return [] }
        let geometry = PageGeometry(setup: content.style.pageSetup)
        var result: Set<BoxID> = []
        for box in template.boxes {
            guard case .text(let style) = box.content, let text = page.text[box.id], !text.paragraphs.isEmpty
            else { continue }
            let rect = geometry.renderRect(for: box).insetBy(dx: CGFloat(style.padding), dy: CGFloat(style.padding))
            let layout = TextBoxLayout(text: text, typography: content.style.typography,
                                       containerSize: CGSize(width: max(0, rect.width), height: max(0, rect.height)))
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

        if let slot = page.images[box.id], let placement = slot.placement,
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
        let inner = rect.insetBy(dx: CGFloat(style.padding), dy: CGFloat(style.padding))
        guard inner.width > 0, inner.height > 0 else { return }
        let layout = TextBoxLayout(text: text, typography: typography, containerSize: inner.size)
        layout.draw(in: ctx, origin: inner.origin)
    }

    private func drawGuides(template: Template, geometry: PageGeometry, ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setLineWidth(0.75)
        ctx.setLineDash(phase: 0, lengths: [4, 3])
        ctx.setStrokeColor(Self.safeAreaGuide)
        ctx.stroke(geometry.safeArea)
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

    // MARK: Helpers

    /// Rotates the context around the box centre (clockwise on the page for positive degrees).
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
