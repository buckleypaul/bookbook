import Foundation

/// BookBook's own attributed-run model (architecture.md §4.2). Not RTF, not an archived
/// `NSAttributedString`. Conversion lives in `BBLayout.RichTextBridge` only.
public struct RichText: Hashable, Codable, Sendable {
    public var paragraphs: [Paragraph]

    public init(paragraphs: [Paragraph] = []) {
        self.paragraphs = paragraphs
    }

    /// Plain paragraphs, one run each, no overrides.
    public init(plain text: String) {
        self.paragraphs = text.components(separatedBy: "\n").map { Paragraph(runs: [Run(text: $0)]) }
    }

    public static let empty = RichText()

    /// Paragraphs joined with "\n"; used for prompts (story text) and search.
    public var plainText: String {
        paragraphs.map { $0.runs.map(\.text).joined() }.joined(separator: "\n")
    }

    public var isEmpty: Bool {
        plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public struct Paragraph: Hashable, Codable, Sendable {
    public var runs: [Run]
    /// Overrides the style guide alignment.
    public var alignment: TextAlignment?

    public init(runs: [Run], alignment: TextAlignment? = nil) {
        self.runs = runs
        self.alignment = alignment
    }
}

public struct Run: Hashable, Codable, Sendable {
    public var text: String
    public var bold: Bool
    public var italic: Bool
    public var underline: Bool
    /// PostScript name; overrides the style default.
    public var fontFamily: String?
    public var size: Double?
    public var color: RGBA?

    public init(text: String, bold: Bool = false, italic: Bool = false, underline: Bool = false,
                fontFamily: String? = nil, size: Double? = nil, color: RGBA? = nil) {
        self.text = text
        self.bold = bold
        self.italic = italic
        self.underline = underline
        self.fontFamily = fontFamily
        self.size = size
        self.color = color
    }
}
