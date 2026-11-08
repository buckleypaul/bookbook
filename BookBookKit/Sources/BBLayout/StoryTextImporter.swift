import AppKit
import BBModel

/// How story text is split into pages (PD §8.5).
public enum StorySplitRule: Hashable, Sendable {
    /// One or more empty (whitespace-only) lines separate pages.
    case blankLines
    /// A line whose trimmed text equals the marker (e.g. `---`) separates pages. Blank lines
    /// inside a page are then kept as paragraph breaks, but leading/trailing empty
    /// paragraphs of each page are trimmed.
    case marker(String)
}

public enum StoryImportError: Error, Hashable, Sendable {
    case unreadable
    case unsupportedType
}

/// Story text import (A §10 `StoryTextImporter`, Phase 5). Reads plain or rich text, keeps
/// the formatting RichText supports (bold, italic, underline, font, size, colour, alignment)
/// via `RichTextBridge`, normalises CRLF/CR to LF, and splits into pages. Pages that end up
/// empty are dropped.
@MainActor
public enum StoryTextImporter {
    /// Reads a `.txt` (UTF-8, falling back to detected encoding) or `.rtf` file.
    public static func read(_ url: URL, typography: Typography) throws(StoryImportError) -> RichText {
        fatalError("Phase 5 lane L1")
    }

    /// Plain (pasted) text as RichText with no overrides.
    public static func richText(fromPlain text: String) -> RichText {
        fatalError("Phase 5 lane L1")
    }

    public static func split(_ text: RichText, rule: StorySplitRule) -> [RichText] {
        fatalError("Phase 5 lane L1")
    }
}
