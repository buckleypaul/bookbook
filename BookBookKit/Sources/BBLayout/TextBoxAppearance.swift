import BBModel
import CoreGraphics
import Foundation

/// How one text box looks on one page: the book typography resolved for the box's role, the
/// template box's `TextBoxStyle` and the page's AI text style (A §7.13), in that order (a run's
/// own attributes still win). The renderer, overflow checks, the inline editor and hit-testing
/// all use this, so screen, editor and export agree.
public struct TextBoxAppearance: Hashable, Sendable {
    public var typography: Typography
    /// Inset of the text inside the box's render rect, in points.
    public var padding: Double
    /// Panel fill behind the text, or nil.
    public var background: RGBA?
    /// The AI decoration drawn behind the panel and text (stretched to the render rect), or nil.
    public var decoration: ImageRef?

    public init(typography: Typography, padding: Double, background: RGBA?, decoration: ImageRef?) {
        self.typography = typography
        self.padding = padding
        self.background = background
        self.decoration = decoration
    }

    /// `pageID` nil (template editor, layout previews) = no page style. `renderSize` is the
    /// box's render rect size in points (for the style's relative inset).
    public static func resolve(box: Box, style: TextBoxStyle, pageID: PageID?, content: BookContent,
                               renderSize: CGSize) -> TextBoxAppearance {
        let base = content.style.typography.resolved(for: box.role).applying(style)
        guard let pageID, let applied = content.appliedTextStyle(page: pageID, box: box.id) else {
            return TextBoxAppearance(typography: base, padding: style.padding, background: style.background,
                                     decoration: nil)
        }
        let size = PointSize(width: Double(renderSize.width), height: Double(renderSize.height))
        return TextBoxAppearance(typography: base.applying(applied.styling),
                                 padding: applied.styling.inset(boxSize: size, templatePadding: style.padding),
                                 background: applied.styling.background, decoration: applied.decoration)
    }

    /// `rect` inset by the padding (the text container), or `rect` if that leaves nothing.
    public func textRect(in rect: CGRect) -> CGRect {
        let inner = rect.insetBy(dx: CGFloat(padding), dy: CGFloat(padding))
        return inner.width > 0 && inner.height > 0 ? inner : rect
    }
}
