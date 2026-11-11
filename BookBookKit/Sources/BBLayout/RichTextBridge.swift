import AppKit
import CoreText
import BBModel
import Foundation

/// The only place `RichText` ⇄ `NSAttributedString` conversion happens (A §4.2). Style-guide
/// defaults are resolved here; runs without overrides follow the style guide.
///
/// - Fonts are looked up by PostScript name (`Run.fontFamily`, else `Typography.bodyFont`).
///   A missing font falls back to the system font at the same size.
/// - `Run.bold`/`Run.italic` are relative to the run's base face (the face named by
///   `Run.fontFamily`, else `Typography.bodyFont`): a flag set means "the opposite of what the
///   base face has". With a regular base face that is plain bold/italic; with a bold base face
///   (the default title font, `AvenirNext-Bold`) an unformatted run draws bold and reads back as
///   `bold: false`, so it follows the style when the font changes, and `bold: true` draws the
///   family's regular weight. The flag picks the family's other face through `NSFontManager`.
///   If the family has no bold/italic face, they are synthesized (negative stroke width for bold,
///   a sheared font matrix for italic), so the flags survive a round trip. (TextKit 2 ignores the
///   `.obliqueness` attribute when drawing, so italic is a font property, not an attribute.) A family with no non-bold or
///   non-italic face can't draw the "off" state and draws its base face instead.
/// - Paragraphs are separated by "\n". Each paragraph gets a paragraph style built from the
///   typography (alignment, `lineHeightMultiple` = `lineSpacing`), with its alignment override.
///
/// Normal form (what `richText(from:)` returns): an empty string is `RichText.empty`; adjacent
/// runs with equal formatting are merged; empty runs are dropped except that an empty paragraph
/// holds one empty run; overrides equal to the style default are nil.
@MainActor
public enum RichTextBridge {
    /// Remembers the PostScript name a run asked for, so a missing font (drawn with the system
    /// fallback) keeps its name through a round trip. Ignored if the font has since changed.
    public static let requestedFontKey = NSAttributedString.Key("app.bookbook.requestedFont")

    /// Stroke width (percent of point size, negative = fill and stroke) used for synthetic bold.
    static let syntheticBoldStrokeWidth: CGFloat = -3
    /// Shear (x per unit of y) of the font matrix used for synthetic italic.
    static let syntheticObliqueness: CGFloat = 0.2

    // MARK: RichText → NSAttributedString

    public static func attributedString(from text: RichText, typography: Typography) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (index, paragraph) in text.paragraphs.enumerated() {
            let paragraphStyle = paragraphStyle(typography: typography, alignment: paragraph.alignment)
            let runs = paragraph.runs.filter { !$0.text.isEmpty }
            for run in runs {
                var attributes = runAttributes(run, typography: typography)
                attributes[.paragraphStyle] = paragraphStyle
                result.append(NSAttributedString(string: run.text, attributes: attributes))
            }
            if index < text.paragraphs.count - 1 {
                // The separator carries the paragraph's last formatting (or its first empty run's).
                let source = runs.last ?? paragraph.runs.first ?? Run(text: "")
                var attributes = runAttributes(source, typography: typography)
                attributes[.paragraphStyle] = paragraphStyle
                result.append(NSAttributedString(string: "\n", attributes: attributes))
            }
        }
        return result
    }

    /// Typing attributes for an empty editor (font, colour, paragraph style from the style guide).
    public static func defaultAttributes(typography: Typography) -> [NSAttributedString.Key: Any] {
        var attributes = runAttributes(Run(text: ""), typography: typography)
        attributes[.paragraphStyle] = paragraphStyle(typography: typography, alignment: nil)
        return attributes
    }

    /// Whether `run` is drawn bold / italic (real face or synthesized): its base face's traits
    /// with the relative flags applied. The format bar shows this, not the stored flags (A §4.2).
    public static func drawnTraits(of run: Run, typography: Typography) -> (bold: Bool, italic: Bool) {
        let name = run.fontFamily ?? typography.bodyFont.postScriptName
        let resolved = resolveFont(postScriptName: name, size: CGFloat(run.size ?? typography.bodySize),
                                   toggleBold: run.bold, toggleItalic: run.italic)
        let traits = resolved.font.fontDescriptor.symbolicTraits
        return (traits.contains(.bold) || resolved.syntheticBold, traits.contains(.italic) || resolved.syntheticItalic)
    }

    static func runAttributes(_ run: Run, typography: Typography) -> [NSAttributedString.Key: Any] {
        let name = run.fontFamily ?? typography.bodyFont.postScriptName
        let size = CGFloat(run.size ?? typography.bodySize)
        let resolved = resolveFont(postScriptName: name, size: size, toggleBold: run.bold, toggleItalic: run.italic)
        let color = run.color ?? typography.color
        var attributes: [NSAttributedString.Key: Any] = [
            .font: resolved.font,
            .foregroundColor: nsColor(color),
            requestedFontKey: name,
        ]
        if run.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if resolved.syntheticBold { attributes[.strokeWidth] = syntheticBoldStrokeWidth }
        return attributes
    }

    static func paragraphStyle(typography: Typography, alignment: TextAlignment?) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = nsAlignment(alignment ?? typography.alignment)
        style.lineHeightMultiple = CGFloat(typography.lineSpacing)
        style.lineBreakMode = .byWordWrapping
        return style
    }

    // MARK: NSAttributedString → RichText

    /// Inverse of `attributedString(from:typography:)`. Attributes equal to the style default
    /// become nil overrides, so `richText(attributedString(x)) == x` for normalized input.
    public static func richText(from string: NSAttributedString, typography: Typography) -> RichText {
        let ns = string.string as NSString
        guard ns.length > 0 else { return .empty }
        var paragraphs: [Paragraph] = []
        var start = 0
        while start <= ns.length {
            let searchRange = NSRange(location: start, length: ns.length - start)
            let newline = ns.range(of: "\n", options: .literal, range: searchRange)
            let end = newline.location == NSNotFound ? ns.length : newline.location
            paragraphs.append(paragraph(in: string, range: NSRange(location: start, length: end - start),
                                        separatorAt: newline.location == NSNotFound ? nil : end,
                                        typography: typography))
            if newline.location == NSNotFound { break }
            start = end + 1
        }
        return RichText(paragraphs: paragraphs)
    }

    private static func paragraph(in string: NSAttributedString, range: NSRange, separatorAt: Int?,
                                  typography: Typography) -> Paragraph {
        // Alignment comes from the paragraph's first character (or its separator if empty).
        let probe = range.length > 0 ? range.location : separatorAt
        var alignment: TextAlignment?
        if let probe, let style = string.attribute(.paragraphStyle, at: probe, effectiveRange: nil) as? NSParagraphStyle {
            let value = modelAlignment(style.alignment)
            alignment = value == typography.alignment ? nil : value
        }

        var runs: [Run] = []
        if range.length > 0 {
            string.enumerateAttributes(in: range, options: []) { attributes, subrange, _ in
                let text = (string.string as NSString).substring(with: subrange)
                let run = run(text: text, attributes: attributes, typography: typography)
                if let last = runs.last, sameFormatting(last, run) {
                    runs[runs.count - 1].text += text
                } else {
                    runs.append(run)
                }
            }
        } else if let separatorAt {
            runs = [run(text: "", attributes: string.attributes(at: separatorAt, effectiveRange: nil),
                        typography: typography)]
        } else {
            runs = [Run(text: "")]
        }
        return Paragraph(runs: runs, alignment: alignment)
    }

    private static func run(text: String, attributes: [NSAttributedString.Key: Any], typography: Typography) -> Run {
        let defaultSize = CGFloat(typography.bodySize)
        guard let font = attributes[.font] as? NSFont else {
            return Run(text: text, underline: isUnderlined(attributes),
                       color: colorOverride(attributes, typography: typography))
        }
        let traits = font.fontDescriptor.symbolicTraits
        let drawnBold = traits.contains(.bold) || ((attributes[.strokeWidth] as? CGFloat).map { $0 < 0 } ?? false)
        let drawnItalic = traits.contains(.italic) || isSheared(font)
            || ((attributes[.obliqueness] as? CGFloat).map { $0 > 0 } ?? false)
        let size = font.pointSize
        let baseName = baseFontName(of: font)

        // Which PostScript name does this run use? Prefer the requested name when it still
        // resolves to this font (keeps missing-font names); otherwise the font's own base face.
        var family = baseName
        let requestedName = attributes[requestedFontKey] as? String
        if let requested = requestedName {
            let requestedBase = baseFontName(of: baseFace(postScriptName: requested, size: size))
            // A missing font is drawn with the system font (whose bold/italic faces can have
            // differently named bases), so accept the requested name when the run uses that fallback.
            let usesSystemFallback = font.fontName.hasPrefix(".")
            if requestedBase == baseName || (NSFont(name: requested, size: size) == nil && usesSystemFallback) {
                family = requested
            }
        }
        // The style font only if the run really names it. Another face of the style font's family
        // (AvenirNext-Regular under an AvenirNext-Bold title) is an override. Only text without a
        // requested name (pasted, not written by this bridge) falls back to matching the family's
        // base face, since nothing else says which face it meant.
        let bodyName = typography.bodyFont.postScriptName
        let isDefaultFamily = family == bodyName
            || (requestedName == nil && family == baseName
                && baseFontName(of: baseFace(postScriptName: bodyName, size: size)) == baseName)

        // Flags are relative to the base face the run will be written with (A §4.2).
        let baseTraits = baseFace(postScriptName: isDefaultFamily ? bodyName : family, size: size)
            .fontDescriptor.symbolicTraits
        let bold = drawnBold != baseTraits.contains(.bold)
        let italic = drawnItalic != baseTraits.contains(.italic)

        return Run(text: text, bold: bold, italic: italic, underline: isUnderlined(attributes),
                   fontFamily: isDefaultFamily ? nil : family,
                   size: abs(size - defaultSize) < 0.001 ? nil : Double(size),
                   color: colorOverride(attributes, typography: typography))
    }

    private static func isUnderlined(_ attributes: [NSAttributedString.Key: Any]) -> Bool {
        ((attributes[.underlineStyle] as? Int) ?? 0) != 0
    }

    private static func colorOverride(_ attributes: [NSAttributedString.Key: Any], typography: Typography) -> RGBA? {
        guard let color = attributes[.foregroundColor] as? NSColor, let rgba = rgba(color) else { return nil }
        return rgba == typography.color ? nil : rgba
    }

    /// Equal run formatting (everything but the text), so adjacent runs can merge.
    static func sameFormatting(_ a: Run, _ b: Run) -> Bool {
        a.bold == b.bold && a.italic == b.italic && a.underline == b.underline
            && a.fontFamily == b.fontFamily && a.size == b.size && a.color == b.color
    }

    // MARK: Fonts

    struct ResolvedFont {
        var font: NSFont
        var syntheticBold: Bool
        var syntheticItalic: Bool
    }

    /// The face a PostScript name names; the system font if it is missing.
    static func baseFace(postScriptName: String, size: CGFloat) -> NSFont {
        NSFont(name: postScriptName, size: size) ?? NSFont.systemFont(ofSize: size)
    }

    /// The base face for a PostScript name with bold/italic toggled relative to it: a toggle on a
    /// regular face adds the trait (real face, else synthesized); on a bold/italic face it removes
    /// it (if the family has such a face). System font if the name is missing.
    static func resolveFont(postScriptName: String, size: CGFloat, toggleBold: Bool, toggleItalic: Bool) -> ResolvedFont {
        var font = baseFace(postScriptName: postScriptName, size: size)
        let manager = NSFontManager.shared
        var syntheticBold = false
        var syntheticItalic = false
        if toggleBold {
            if font.fontDescriptor.symbolicTraits.contains(.bold) {
                font = manager.convert(font, toNotHaveTrait: .boldFontMask)
            } else {
                let converted = manager.convert(font, toHaveTrait: .boldFontMask)
                if converted.fontDescriptor.symbolicTraits.contains(.bold) { font = converted } else { syntheticBold = true }
            }
        }
        if toggleItalic {
            if font.fontDescriptor.symbolicTraits.contains(.italic) {
                font = manager.convert(font, toNotHaveTrait: .italicFontMask)
            } else {
                let converted = manager.convert(font, toHaveTrait: .italicFontMask)
                if converted.fontDescriptor.symbolicTraits.contains(.italic) {
                    font = converted
                } else {
                    font = sheared(font)
                    syntheticItalic = true
                }
            }
        }
        return ResolvedFont(font: font, syntheticBold: syntheticBold, syntheticItalic: syntheticItalic)
    }

    /// `font` with a sheared matrix (synthetic italic). TextKit 2 draws the shear in the editor,
    /// the canvas and PDF export alike.
    static func sheared(_ font: NSFont) -> NSFont {
        var matrix = CGAffineTransform(a: 1, b: 0, c: syntheticObliqueness, d: 1, tx: 0, ty: 0)
        return CTFontCreateWithFontDescriptor(font.fontDescriptor as CTFontDescriptor, font.pointSize, &matrix) as NSFont
    }

    /// True if the font's matrix leans right (synthetic italic).
    static func isSheared(_ font: NSFont) -> Bool {
        CTFontGetMatrix(font as CTFont).c > 0.001
    }

    /// The PostScript name of the font's upright, regular-weight face in the same family.
    static func baseFontName(of font: NSFont) -> String {
        let manager = NSFontManager.shared
        var base = font
        if base.fontDescriptor.symbolicTraits.contains(.bold) {
            base = manager.convert(base, toNotHaveTrait: .boldFontMask)
        }
        if base.fontDescriptor.symbolicTraits.contains(.italic) {
            base = manager.convert(base, toNotHaveTrait: .italicFontMask)
        }
        return base.fontName
    }

    // MARK: Colours and alignment

    static func nsColor(_ c: RGBA) -> NSColor {
        NSColor(srgbRed: CGFloat(c.red), green: CGFloat(c.green), blue: CGFloat(c.blue), alpha: CGFloat(c.alpha))
    }

    /// `color`'s sRGB components; nil if it has no sRGB equivalent (a pattern colour).
    public nonisolated static func rgba(_ color: NSColor) -> RGBA? {
        guard let srgb = color.usingColorSpace(.sRGB) else { return nil }
        return RGBA(red: Double(srgb.redComponent), green: Double(srgb.greenComponent),
                    blue: Double(srgb.blueComponent), alpha: Double(srgb.alphaComponent))
    }

    static func nsAlignment(_ alignment: TextAlignment) -> NSTextAlignment {
        switch alignment {
        case .leading: .natural
        case .center: .center
        case .trailing: .right
        case .justified: .justified
        }
    }

    /// The model alignment for a paragraph style's alignment (`.natural`, `.left` → leading).
    public nonisolated static func modelAlignment(_ alignment: NSTextAlignment) -> TextAlignment {
        switch alignment {
        case .center: .center
        case .right: .trailing
        case .justified: .justified
        default: .leading
        }
    }
}
