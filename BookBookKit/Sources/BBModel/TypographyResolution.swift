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
}
