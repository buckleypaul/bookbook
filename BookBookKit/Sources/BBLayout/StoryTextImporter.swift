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
        switch url.pathExtension.lowercased() {
        case "rtf":
            guard let data = try? Data(contentsOf: url),
                  let attributed = try? NSAttributedString(
                      data: data, options: [.documentType: NSAttributedString.DocumentType.rtf],
                      documentAttributes: nil)
            else { throw .unreadable }
            return richText(from: attributed, typography: typography)
        case "txt":
            guard let data = try? Data(contentsOf: url) else { throw .unreadable }
            if let text = String(data: data, encoding: .utf8) { return richText(fromPlain: text) }
            var converted: NSString?
            let encoding = NSString.stringEncoding(for: data, encodingOptions: nil, convertedString: &converted,
                                                   usedLossyConversion: nil)
            if encoding != 0, let converted { return richText(fromPlain: converted as String) }
            guard let text = String(data: data, encoding: .isoLatin1) else { throw .unreadable }
            return richText(fromPlain: text)
        default:
            throw .unsupportedType
        }
    }

    /// Plain (pasted) text as RichText with no overrides.
    public static func richText(fromPlain text: String) -> RichText {
        RichText(plain: normalizeNewlines(text))
    }

    public static func split(_ text: RichText, rule: StorySplitRule) -> [RichText] {
        func plain(_ p: Paragraph) -> String { p.runs.map(\.text).joined() }
        func isBlank(_ p: Paragraph) -> Bool {
            plain(p).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        var chunks: [[Paragraph]] = [[]]
        for paragraph in text.paragraphs {
            let isSeparator: Bool
            switch rule {
            case .blankLines:
                isSeparator = isBlank(paragraph)
            case .marker(let marker):
                isSeparator = plain(paragraph).trimmingCharacters(in: .whitespacesAndNewlines)
                    == marker.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if isSeparator { chunks.append([]) } else { chunks[chunks.count - 1].append(paragraph) }
        }
        return chunks.compactMap { chunk in
            var paragraphs = chunk[...]
            while let first = paragraphs.first, isBlank(first) { paragraphs = paragraphs.dropFirst() }
            while let last = paragraphs.last, isBlank(last) { paragraphs = paragraphs.dropLast() }
            return paragraphs.isEmpty ? nil : RichText(paragraphs: Array(paragraphs))
        }
    }

    private static func normalizeNewlines(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n")
    }

    private static func richText(from attributed: NSAttributedString, typography: Typography) -> RichText {
        let mutable = NSMutableAttributedString(attributedString: attributed)
        for pattern in ["\r\n", "\r", "\u{2028}", "\u{2029}"] {
            while true {
                let range = (mutable.string as NSString).range(of: pattern)
                if range.location == NSNotFound { break }
                mutable.replaceCharacters(in: range, with: "\n")
            }
        }
        return RichTextBridge.richText(from: mutable, typography: typography)
    }
}
