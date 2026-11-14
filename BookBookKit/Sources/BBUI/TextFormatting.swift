import BBModel
import Foundation
import Observation

/// A formatting change from the format bar or the Format menu (PD §8.6, Phase 4 contract).
/// `nil` values clear the run/paragraph override so the text follows the style guide again.
public enum FormatAction: Hashable, Sendable {
    case toggleBold
    case toggleItalic
    case toggleUnderline
    /// PostScript name of the family's regular face; nil = style default.
    case setFont(String?)
    case setSize(Double?)
    case setColor(RGBA?)
    case setAlignment(TextAlignment?)
    case biggerText
    case smallerText
}

/// The formatting at the editor's selection. `nil` fields mean "mixed" (bold/italic/underline)
/// or "follows the style" / "mixed" (font, size, colour, alignment). The `resolved…` fields and
/// `isFontMixed` tell those two apart: they hold what the text is drawn with, nil only when
/// the selection is mixed.
public struct FormatState: Hashable, Sendable {
    public var bold: Bool?
    public var italic: Bool?
    public var underline: Bool?
    public var font: String?
    public var size: Double?
    public var color: RGBA?
    public var alignment: TextAlignment?
    /// The drawn size (the override, or the style's); nil only when the selection mixes sizes.
    public var resolvedSize: Double?
    /// The drawn colour (the override, or the style's); nil only when the selection mixes colours.
    public var resolvedColor: RGBA?
    /// True when the selection mixes fonts (`font` is then nil but doesn't mean the style's).
    public var isFontMixed: Bool

    public init(bold: Bool? = false, italic: Bool? = false, underline: Bool? = false, font: String? = nil,
                size: Double? = nil, color: RGBA? = nil, alignment: TextAlignment? = nil,
                resolvedSize: Double? = nil, resolvedColor: RGBA? = nil, isFontMixed: Bool = false) {
        self.bold = bold
        self.italic = italic
        self.underline = underline
        self.font = font
        self.size = size
        self.color = color
        self.alignment = alignment
        self.resolvedSize = resolvedSize
        self.resolvedColor = resolvedColor
        self.isFontMixed = isFontMixed
    }
}

/// Implemented by the inline text editor. Applying an action edits the `NSTextView`'s
/// storage and sends one non-coalescing `SetRichText` (A §6.3: formatting ends a typing group).
@MainActor
public protocol TextFormatTarget: AnyObject {
    func apply(_ action: FormatAction)
}

/// One per book window (`BookDocument.formatting`). The format bar and the Format menu read
/// `state` and call `perform`; the editor sets `target` and keeps `state` current.
@MainActor @Observable
public final class TextFormatController {
    /// nil when no text box is being edited (format controls are disabled).
    public var state: FormatState?
    @ObservationIgnored public weak var target: (any TextFormatTarget)?

    public init() {}

    public var isEditing: Bool { state != nil && target != nil }

    public func perform(_ action: FormatAction) {
        target?.apply(action)
    }
}
