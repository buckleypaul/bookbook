import BBModel
import CoreGraphics
import Foundation

/// Where and how a page number is drawn (A §8.4, PD §8.2). Pure geometry plus one draw call, so
/// tests can check placement without pixels.
@MainActor
enum PageNumberDrawing {
    /// The rect a mark's text is laid out in, and its horizontal alignment.
    struct Placement: Equatable {
        var rect: CGRect
        var alignment: TextAlignment
    }

    /// One half of the page: the whole trim for a single page, half for a spread.
    static func halfRect(template: Template, mark: PageNumberMark, geometry: PageGeometry) -> CGRect {
        let size = geometry.trimSize
        guard template.kind == .spread else { return geometry.trimRect }
        let width = size.width / 2
        return CGRect(x: mark.half == 0 ? 0 : width, y: 0, width: width, height: size.height)
    }

    static func placement(for mark: PageNumberMark, style: PageNumberStyle, template: Template,
                          geometry: PageGeometry) -> Placement {
        let half = halfRect(template: template, mark: mark, geometry: geometry)
        // A template slot wins; for spreads, the one whose centre lies in this half.
        if let slot = template.boxes.first(where: {
            let r = geometry.renderRect(for: $0)
            return $0.role == .pageNumberSlot && half.contains(CGPoint(x: r.midX, y: r.midY))
        }) {
            return Placement(rect: geometry.renderRect(for: slot), alignment: .center)
        }

        let margins = geometry.setup.margins
        let left = half.minX + CGFloat(margins.leading)
        let right = max(left, half.maxX - CGFloat(margins.trailing))
        let height = CGFloat(max(1, style.size)) * 1.4
        let trimHeight = geometry.trimSize.height
        let isBottom: Bool
        switch style.position {
        case .bottomCenter, .bottomOuter, .bottomInner: isBottom = true
        case .topCenter, .topOuter, .topInner: isBottom = false
        }
        // Centre the line in the margin band, kept fully inside the trim.
        let bandMid = isBottom ? trimHeight - CGFloat(margins.bottom) / 2 : CGFloat(margins.top) / 2
        let y = min(max(0, bandMid - height / 2), max(0, trimHeight - height))

        let alignment: TextAlignment
        switch style.position {
        case .bottomCenter, .topCenter: alignment = .center
        case .bottomOuter, .topOuter: alignment = mark.isLeftHand ? .leading : .trailing
        case .bottomInner, .topInner: alignment = mark.isLeftHand ? .trailing : .leading
        }
        return Placement(rect: CGRect(x: left, y: y, width: right - left, height: height), alignment: alignment)
    }

    /// Draws `mark`, reusing a layout from `layouts` when given.
    static func draw(_ mark: PageNumberMark, content: BookContent, template: Template, geometry: PageGeometry,
                     layouts: TextBoxLayoutCache? = nil, ctx: CGContext) {
        guard !mark.text.isEmpty else { return }
        let style = content.style.pageNumbers
        let placement = placement(for: mark, style: style, template: template, geometry: geometry)
        guard placement.rect.width > 0, placement.rect.height > 0 else { return }

        var typography = content.style.typography
        typography.alignment = placement.alignment
        typography.lineSpacing = 1
        let run = Run(text: mark.text, fontFamily: style.fontFamily ?? typography.bodyFont.postScriptName,
                      size: style.size, color: style.color ?? typography.color)
        let text = RichText(paragraphs: [Paragraph(runs: [run])])
        let layout = layouts?.layout(text: text, typography: typography, containerSize: placement.rect.size)
            ?? TextBoxLayout(text: text, typography: typography, containerSize: placement.rect.size)
        // Centre the line vertically in its rect.
        let offset = max(0, (placement.rect.height - layout.usedHeight) / 2)
        layout.draw(in: ctx, origin: CGPoint(x: placement.rect.minX, y: placement.rect.minY + offset))
    }
}
