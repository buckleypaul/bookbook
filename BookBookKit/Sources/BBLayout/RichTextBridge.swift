import AppKit
import BBModel
import Foundation

// Owned by the Layout lane. Contract stub: signatures are frozen, bodies are placeholders.

/// The only place `RichText` ⇄ `NSAttributedString` conversion happens (A §4.2). Style-guide
/// defaults are resolved here; runs without overrides follow the style guide.
@MainActor
public enum RichTextBridge {
    public static func attributedString(from text: RichText, typography: Typography) -> NSAttributedString {
        fatalError("Phase 2 Layout lane: not implemented")
    }

    /// Inverse of `attributedString(from:typography:)`. Attributes equal to the style default
    /// become nil overrides, so `richText(attributedString(x)) == x` for normalized input.
    public static func richText(from string: NSAttributedString, typography: Typography) -> RichText {
        fatalError("Phase 2 Layout lane: not implemented")
    }

    /// Typing attributes for an empty editor (font, colour, paragraph style from the style guide).
    public static func defaultAttributes(typography: Typography) -> [NSAttributedString.Key: Any] {
        fatalError("Phase 2 Layout lane: not implemented")
    }
}
