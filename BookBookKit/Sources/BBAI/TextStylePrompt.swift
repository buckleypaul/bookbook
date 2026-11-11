import BBAICore
import BBModel
import Foundation

// AI text styling (A §7.13): the text-model half. BBUI describes the box (`TextStyleSnapshot`),
// `TextStylePrompt` renders the request, the provider answers with a `TextStyleDraft`, and
// `TextStyleNormalizer` turns it into `TextStyling` plus the decoration prompt.

/// A text box's look now, as BBUI resolves it (template style, book typography and any applied
/// text style), for the text-style prompt and the normaliser.
public struct TextStyleSnapshot: Hashable, Sendable {
    /// The family name of the font the text is drawn in.
    public var fontFamily: String
    /// Points.
    public var fontSize: Double
    public var textColor: RGBA
    public var alignment: TextAlignment
    /// Fraction of the box's shorter side (`TextStyling.insetFraction`).
    public var textInset: Double
    public var panelColor: RGBA?
    /// The current decoration's description, if the box is styled with one.
    public var decoration: String?

    public init(fontFamily: String, fontSize: Double, textColor: RGBA, alignment: TextAlignment, textInset: Double,
                panelColor: RGBA?, decoration: String?) {
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.textColor = textColor
        self.alignment = alignment
        self.textInset = textInset
        self.panelColor = panelColor
        self.decoration = decoration
    }
}

public enum TextStylePrompt {
    public static let set = "textstyle-v1"
    /// The box's text is cut to this many characters (an ellipsis marks the cut).
    static let maxTextCharacters = 600

    /// Renders a styling request for one text box.
    /// - fonts: allowed font family names (BBUI passes a curated, installed list).
    /// - current: the box's look now.
    /// - history: earlier instructions in this box's styling thread (oldest first), excluding `instruction`.
    public static func request(instruction: String, boxText: String, boxRole: BoxRole?, boxSizePoints: PointSize,
                               current: TextStyleSnapshot, history: [String], styleDescription: String,
                               fonts: [String], model: CatalogTextModel) -> TextStyleRequest {
        let earlier = history.map(\.trimmed).filter { !$0.isEmpty }
        let style = styleDescription.trimmed
        let fontList = fonts.map(\.trimmed).filter { !$0.isEmpty }
        let values: [String: String] = [
            "instruction": instruction.trimmed,
            "history": earlier.isEmpty ? "(none)" : earlier.map { "- \($0)" }.joined(separator: "\n"),
            "style": style.isEmpty ? "(not described)" : style,
            "role": roleText(boxRole),
            "size": sizeText(boxSizePoints),
            "text": textExcerpt(boxText),
            "current": json(current),
            "fonts": fontList.isEmpty ? "(none: use null for fontFamily)" : fontList.map { "- \($0)" }.joined(separator: "\n"),
        ]
        let user = PromptTemplates.render(PromptTemplates.text(for: "user", set: set) ?? "", values)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return TextStyleRequest(model: model, system: PromptTemplates.text(for: "system", set: set) ?? "", user: user)
    }

    static func roleText(_ role: BoxRole?) -> String {
        switch role {
        case .title: "book title (cover or title page)"
        case .author: "author name"
        case .pageNumberSlot: "page number"
        case nil: "story text"
        }
    }

    /// e.g. "360 x 120 pt (landscape, about 3:1)".
    static func sizeText(_ size: PointSize) -> String {
        let aspect = size.height > 0 ? size.width / size.height : 1
        return "\(number(size.width)) x \(number(size.height)) pt (\(ContextAssembler.describeAspect(aspect)))"
    }

    static func textExcerpt(_ text: String) -> String {
        let trimmed = text.trimmed
        guard !trimmed.isEmpty else { return "(empty)" }
        guard trimmed.count > maxTextCharacters else { return trimmed }
        return String(trimmed.prefix(maxTextCharacters)).trimmed + "…"
    }

    /// The current look in the schema's field names (`null` for none), keys sorted.
    static func json(_ current: TextStyleSnapshot) -> String {
        let decoration = current.decoration?.trimmed
        let object: [String: Any] = [
            "fontFamily": current.fontFamily,
            "fontSize": rounded(current.fontSize),
            "textColor": TemplateNormalizer.hex(current.textColor),
            "alignment": current.alignment.rawValue,
            "textInset": rounded(current.textInset, places: 3),
            "panelColor": current.panelColor.map(TemplateNormalizer.hex) ?? NSNull(),
            "decoration": decoration.flatMap { $0.isEmpty ? nil : $0 } ?? NSNull(),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    private static func rounded(_ value: Double, places: Int = 1) -> Double {
        guard value.isFinite else { return 0 }
        let scale = pow(10, Double(places))
        return (value * scale).rounded() / scale
    }

    private static func number(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
    }
}

/// Validates a `TextStyleDraft` (A §7.13): the font must be one offered, numbers are clamped,
/// colours parsed, and an empty decoration means typography only.
public enum TextStyleNormalizer {
    public static let fontSizeRange = 6.0...288.0
    public static let fallbackSummary = "Styled the text."

    /// - fonts: allowed family name → PostScript name of its regular face (BBUI supplies it).
    /// - current: the box's look now (reserved for keep-values; nil fields in the result keep it).
    public static func styling(from draft: TextStyleDraft, fonts: [String: String],
                               current: TextStyleSnapshot) -> (styling: TextStyling, decorationPrompt: String?, summary: String) {
        let font = draft.fontFamily.flatMap { family in fontRef(family: family, fonts: fonts) }
        let size = draft.fontSize.flatMap { $0.isFinite ? min(max($0, fontSizeRange.lowerBound), fontSizeRange.upperBound) : nil }
        let inset = draft.textInset.isFinite ? min(max(draft.textInset, 0), TextStyling.maxInsetFraction) : 0
        let styling = TextStyling(
            font: font, fontSize: size, color: draft.textColor.flatMap(TemplateNormalizer.parseHex),
            alignment: draft.alignment.flatMap { TextAlignment(rawValue: $0.rawValue) },
            insetFraction: inset, background: draft.panelColor.flatMap(TemplateNormalizer.parseHex))
        let decoration = draft.decoration?.trimmed
        let summary = draft.summary.trimmed
        return (styling, decoration.flatMap { $0.isEmpty ? nil : $0 }, summary.isEmpty ? fallbackSummary : summary)
    }

    /// The allowed family's regular face: an exact name first, then ignoring case and spacing.
    static func fontRef(family: String, fonts: [String: String]) -> FontRef? {
        let wanted = family.trimmed
        if let postScript = fonts[wanted] { return FontRef(postScriptName: postScript) }
        func key(_ name: String) -> String { name.lowercased().filter { !$0.isWhitespace } }
        let folded = key(wanted)
        guard !folded.isEmpty,
              let match = fonts.keys.sorted().first(where: { key($0) == folded }), let postScript = fonts[match]
        else { return nil }
        return FontRef(postScriptName: postScript)
    }
}

extension String {
    fileprivate var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
