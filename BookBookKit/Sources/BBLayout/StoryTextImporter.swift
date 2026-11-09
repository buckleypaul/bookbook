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
/// bold, italic, underline, colour and alignment via `RichTextBridge` (font family and size are
/// dropped so the text takes the body font, Phase 16b #71c), normalises CRLF/CR to LF, and
/// splits into pages. Pages that end up empty are dropped.
@MainActor
public enum StoryTextImporter {
    /// File extensions read as plain text (Phase 16b #71a). Markdown is read as-is (no markup parsing).
    public static let plainTextExtensions: Set<String> = ["txt", "text", "md", "markdown"]
    /// File extensions read as rich text.
    public static let richTextExtensions: Set<String> = ["rtf"]

    /// Reads a plain-text file (`.txt`, `.text`, `.md`, `.markdown`: UTF-8, falling back to the
    /// detected encoding) or an `.rtf` file.
    public static func read(_ url: URL, typography: Typography) throws(StoryImportError) -> RichText {
        let ext = url.pathExtension.lowercased()
        if plainTextExtensions.contains(ext) { return try readPlain(url) }
        switch ext {
        case "rtf":
            guard let data = try? Data(contentsOf: url),
                  let attributed = try? NSAttributedString(
                      data: data, options: [.documentType: NSAttributedString.DocumentType.rtf],
                      documentAttributes: nil)
            else { throw .unreadable }
            return richText(from: attributed, typography: typography)
        default:
            throw .unsupportedType
        }
    }

    private static func readPlain(_ url: URL) throws(StoryImportError) -> RichText {
        guard let data = try? Data(contentsOf: url) else { throw .unreadable }
        if let text = String(data: data, encoding: .utf8) { return richText(fromPlain: text) }
        var converted: NSString?
        let encoding = NSString.stringEncoding(for: data, encodingOptions: nil, convertedString: &converted,
                                               usedLossyConversion: nil)
        if encoding != 0, let converted { return richText(fromPlain: converted as String) }
        guard let text = String(data: data, encoding: .isoLatin1) else { throw .unreadable }
        return richText(fromPlain: text)
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
        return usingBodyFont(RichTextBridge.richText(from: mutable, typography: typography), typography: typography)
    }

    /// Drops each run's font family and size so imported text takes the body font, keeping how
    /// it is drawn bold/italic (flags are re-expressed relative to the body face, A §4.2), and
    /// re-merges runs that now have equal formatting (Phase 16b #71c).
    static func usingBodyFont(_ text: RichText, typography: Typography) -> RichText {
        let bodyTraits = RichTextBridge.baseFace(postScriptName: typography.bodyFont.postScriptName,
                                                 size: CGFloat(typography.bodySize)).fontDescriptor.symbolicTraits
        var result = text
        for p in result.paragraphs.indices {
            var merged: [Run] = []
            for var run in result.paragraphs[p].runs {
                let drawn = RichTextBridge.drawnTraits(of: run, typography: typography)
                run.bold = drawn.bold != bodyTraits.contains(.bold)
                run.italic = drawn.italic != bodyTraits.contains(.italic)
                run.fontFamily = nil
                run.size = nil
                if let last = merged.last, last.bold == run.bold, last.italic == run.italic,
                   last.underline == run.underline, last.color == run.color {
                    merged[merged.count - 1].text += run.text
                } else {
                    merged.append(run)
                }
            }
            if merged.count > 1 { merged.removeAll { $0.text.isEmpty } }
            result.paragraphs[p].runs = merged.isEmpty ? [Run(text: "")] : merged
        }
        return result
    }
}
