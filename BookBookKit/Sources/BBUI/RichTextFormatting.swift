import BBLayout
import BBModel
import Foundation

/// Pure edits of `RichText` over a UTF-16 range of its attributed form (paragraphs joined by
/// one newline), used by the editor's format actions.
@MainActor
enum RichTextFormatting {
    /// Points per step for Bigger / Smaller.
    static let sizeStep: Double = 1
    static let minimumSize: Double = 1

    /// The runs inside `range` (whole runs, unsplit); empty for an empty range.
    static func runs(in range: NSRange, of text: RichText) -> [Run] {
        var result: [Run] = []
        var offset = 0
        for paragraph in text.paragraphs {
            for run in paragraph.runs {
                let length = run.text.utf16.count
                if max(offset, range.location) < min(offset + length, NSMaxRange(range)) { result.append(run) }
                offset += length
            }
            offset += 1 // the newline separator
        }
        return result
    }

    /// Applies `transform` to the characters in `range`, splitting runs at its edges.
    static func applying(_ transform: (inout Run) -> Void, to range: NSRange, of text: RichText) -> RichText {
        var offset = 0
        var paragraphs: [Paragraph] = []
        for paragraph in text.paragraphs {
            var runs: [Run] = []
            for run in paragraph.runs {
                let units = Array(run.text.utf16)
                let start = offset
                offset += units.count
                let lower = min(max(range.location - start, 0), units.count)
                let upper = min(max(NSMaxRange(range) - start, 0), units.count)
                guard lower < upper else {
                    runs.append(run)
                    continue
                }
                for (from, to, inside) in [(0, lower, false), (lower, upper, true), (upper, units.count, false)]
                where from < to {
                    var piece = run
                    piece.text = String(decoding: units[from..<to], as: UTF16.self)
                    if inside { transform(&piece) }
                    runs.append(piece)
                }
            }
            offset += 1 // the newline separator
            paragraphs.append(Paragraph(runs: runs, alignment: paragraph.alignment))
        }
        return RichText(paragraphs: paragraphs)
    }

    /// Sets the alignment of every paragraph `range` touches (the caret's, if it's empty).
    static func settingAlignment(_ alignment: TextAlignment?, in range: NSRange, of text: RichText) -> RichText {
        var copy = text
        if copy.paragraphs.isEmpty { copy.paragraphs = [Paragraph(runs: [Run(text: "")])] }
        for index in paragraphIndexes(in: range, of: copy) { copy.paragraphs[index].alignment = alignment }
        return copy
    }

    /// The common alignment override of the paragraphs `range` touches; nil if mixed or default.
    static func alignment(in range: NSRange, of text: RichText) -> TextAlignment? {
        let values = Set(paragraphIndexes(in: range, of: text).map { text.paragraphs[$0].alignment })
        return values.count == 1 ? values.first ?? nil : nil
    }

    /// Common values of `runs`; nil where they differ (or, for overrides, where none is set).
    /// Bold and italic are what the runs draw (A §4.2: the stored flags are relative to the base
    /// face), so B is on over a bold title even though its runs store `bold: false`.
    static func state(of runs: [Run], typography: Typography) -> FormatState {
        func common<T: Hashable>(_ key: (Run) -> T?) -> T? {
            let values = Set(runs.map(key))
            return values.count == 1 ? values.first ?? nil : nil
        }
        let drawn = runs.map { RichTextBridge.drawnTraits(of: $0, typography: typography) }
        func commonDrawn(_ key: ((bold: Bool, italic: Bool)) -> Bool) -> Bool? {
            let values = Set(drawn.map(key))
            return values.count == 1 ? values.first : nil
        }
        return FormatState(bold: commonDrawn(\.bold), italic: commonDrawn(\.italic),
                           underline: common { $0.underline }, font: common { $0.fontFamily },
                           size: common { $0.size }, color: common { $0.color }, alignment: nil,
                           resolvedSize: common { $0.size ?? typography.bodySize },
                           resolvedColor: common { $0.color ?? typography.color },
                           isFontMixed: Set(runs.map(\.fontFamily)).count > 1)
    }

    /// The run transform for a (non-alignment) action, given the runs it applies to.
    /// Bold and italic toggle what is drawn: if every run draws bold, they all become non-bold,
    /// else all bold; each run's relative flag is set to get there from its base face (A §4.2).
    static func transform(for action: FormatAction, current runs: [Run],
                          typography: Typography) -> ((inout Run) -> Void)? {
        switch action {
        case .toggleBold:
            let value = !runs.allSatisfy { RichTextBridge.drawnTraits(of: $0, typography: typography).bold }
            return { run in
                var base = run
                base.bold = false
                run.bold = RichTextBridge.drawnTraits(of: base, typography: typography).bold != value
            }
        case .toggleItalic:
            let value = !runs.allSatisfy { RichTextBridge.drawnTraits(of: $0, typography: typography).italic }
            return { run in
                var base = run
                base.italic = false
                run.italic = RichTextBridge.drawnTraits(of: base, typography: typography).italic != value
            }
        case .toggleUnderline:
            let value = !runs.allSatisfy(\.underline)
            return { $0.underline = value }
        case .setFont(let name):
            return { $0.fontFamily = name }
        case .setSize(let size):
            return { $0.size = size.map { max(minimumSize, $0) } }
        case .setColor(let color):
            return { $0.color = color }
        case .biggerText, .smallerText:
            let step = action == .biggerText ? sizeStep : -sizeStep
            let base = typography.bodySize
            return { run in run.size = max(minimumSize, (run.size ?? base) + step) }
        case .setAlignment:
            return nil
        }
    }

    /// Paragraphs that `range` touches: those it overlaps, or the caret's if it's empty.
    private static func paragraphIndexes(in range: NSRange, of text: RichText) -> [Int] {
        var result: [Int] = []
        var start = 0
        for (index, paragraph) in text.paragraphs.enumerated() {
            let end = start + paragraph.runs.reduce(0) { $0 + $1.text.utf16.count } // separator at `end`
            let touches = range.length == 0
                ? (range.location >= start && range.location <= end)
                : (range.location <= end && NSMaxRange(range) > start)
            if touches { result.append(index) }
            start = end + 1
        }
        if result.isEmpty, !text.paragraphs.isEmpty { result = [text.paragraphs.count - 1] }
        return result
    }
}
