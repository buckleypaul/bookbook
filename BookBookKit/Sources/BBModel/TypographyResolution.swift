import Foundation

extension Typography {
    /// The typography a text box with `role` lays out with (Phase 4 contract).
    /// `.title` boxes use the title font; every other role (and `nil`) uses the body font.
    public func resolved(for role: BoxRole?) -> Typography {
        guard role == .title else { return self }
        var copy = self
        copy.bodyFont = titleFont
        return copy
    }

    /// This typography with a text box's overrides applied (A 4.2 precedence: run/paragraph
    /// override > box style > style guide). nil overrides leave the style guide's values.
    public func applying(_ style: TextBoxStyle) -> Typography {
        var copy = self
        if let size = style.fontSize { copy.bodySize = size }
        if let alignment = style.alignment { copy.alignment = alignment }
        if let color = style.color { copy.color = color }
        return copy
    }
}
