import AppKit
import BBLayout
import BBModel
import SwiftUI

/// Installed font families and their regular faces, for the format bar and the typography form.
@MainActor
enum FontFamilies {
    static var all: [String] { NSFontManager.shared.availableFontFamilies.sorted() }

    /// PostScript name of the family's regular face.
    static func regularFace(of family: String) -> String? {
        NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 12)?.fontName
    }

    /// Family name for a PostScript name, if the font is available.
    static func family(of postScriptName: String) -> String? {
        NSFont(name: postScriptName, size: 12)?.familyName
    }
}

/// The text format bar (PD §8.6). Reads `document.formatting.state`, sends `FormatAction`s, and is
/// disabled when no text box is being edited. Controls are non-focusable so the text view keeps
/// first responder and the action applies to its selection.
struct FormatBar: View {
    let formatting: TextFormatController
    /// Whether the controls run past the bar's leading / trailing edge (it scrolls): a fade shows there.
    @State private var clippedLeading = false
    @State private var clippedTrailing = false

    /// One alignment segment: its value, label, Format menu shortcut and symbol.
    struct AlignmentChoice {
        var value: BBModel.TextAlignment?
        var title: String
        var shortcut: String?
        var symbol: String
    }

    static let alignments: [AlignmentChoice] = [
        AlignmentChoice(value: nil, title: "Style Default", shortcut: nil, symbol: "paintpalette"),
        AlignmentChoice(value: .leading, title: "Align Left", shortcut: "⌘{", symbol: "text.alignleft"),
        AlignmentChoice(value: .center, title: "Centre", shortcut: "⌘|", symbol: "text.aligncenter"),
        AlignmentChoice(value: .trailing, title: "Align Right", shortcut: "⌘}", symbol: "text.alignright"),
        AlignmentChoice(value: .justified, title: "Justify", shortcut: nil, symbol: "text.justify"),
    ]

    var body: some View {
        // The bar must not set the detail column's minimum width. Its controls are rigid, so a
        // plain HStack's minimum is its full width (about 600 pt, more with a long font name),
        // which is wider than the detail column at the default window size. The split view
        // (`NavigationSplitView` + `.inspector`) then can't satisfy its column constraints, and
        // AppKit aborts the window inside the update-constraints pass ("more Update Constraints
        // in Window passes than there are views"). In a horizontal scroll view the controls keep
        // their size, the bar's minimum width is 0, and a narrow column scrolls the bar instead.
        ScrollView(.horizontal) {
            controls
        }
        .scrollBounceBehavior(.basedOnSize)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.x > 1
        } action: { _, clipped in
            clippedLeading = clipped
        }
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentSize.width - geometry.contentOffset.x - geometry.containerSize.width > 1
        } action: { _, clipped in
            clippedTrailing = clipped
        }
        // A fade over a clipped edge: there's more of the bar to scroll to.
        .overlay(alignment: .leading) { if clippedLeading { edgeFade(.leading) } }
        .overlay(alignment: .trailing) { if clippedTrailing { edgeFade(.trailing) } }
        .fixedSize(horizontal: false, vertical: true)
        .background(Crayon.paperDeep)
        .accessibilityIdentifier("format-bar")
    }

    private func edgeFade(_ edge: HorizontalEdge) -> some View {
        LinearGradient(colors: [Crayon.paperDeep.opacity(0), Crayon.paperDeep],
                       startPoint: edge == .trailing ? .leading : .trailing,
                       endPoint: edge == .trailing ? .trailing : .leading)
            .frame(width: 32)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var controls: some View {
        let state = formatting.state
        return HStack(spacing: 10) {
            HStack(spacing: 2) {
                toggle("bold", "Bold", shortcut: "⌘B", on: state?.bold, .toggleBold)
                toggle("italic", "Italic", shortcut: "⌘I", on: state?.italic, .toggleItalic)
                toggle("underline", "Underline", shortcut: "⌘U", on: state?.underline, .toggleUnderline)
            }
            fontMenu(state)
            HStack(spacing: 4) {
                // The size the text is drawn at (its own or the style's); "–" only when mixed.
                Text(Self.sizeLabel(state))
                    .monospacedDigit()
                    .frame(minWidth: 28)
                Stepper("Text Size", onIncrement: { formatting.perform(.biggerText) },
                        onDecrement: { formatting.perform(.smallerText) })
                    .labelsHidden()
            }
            .help("Text size (Bigger ⌘+, Smaller ⌘-)")
            ColorPicker("Text Colour", selection: colorBinding(state?.resolvedColor), supportsOpacity: false)
                .labelsHidden()
                // A rim, so a dark swatch doesn't vanish into the night theme's bar.
                .overlay {
                    Capsule()
                        .strokeBorder(Crayon.ink.opacity(formatting.isEditing ? 0.35 : 0.15), lineWidth: 1)
                        .padding(-2)
                        .allowsHitTesting(false)
                }
                .help("Text colour")
            Button { formatting.perform(.setColor(nil)) } label: { Image(systemName: "eraser") }
                .help("Use the style's text colour")
                .accessibilityLabel("Use Style Colour")
            alignmentPicker(state?.alignment)
        }
        .buttonStyle(.borderless)
        .focusable(false)
        .disabled(!formatting.isEditing)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    /// The size shown: what the text is drawn at (its override or the style's), "–" when the
    /// selection mixes sizes or nothing is being edited.
    static func sizeLabel(_ state: FormatState?) -> String {
        state?.resolvedSize.map { String(format: "%g", $0) } ?? "–"
    }

    /// The font menu's label: the family, "Style Default" when the text follows the style,
    /// "Mixed" for a mixed selection (or a font that isn't installed).
    static func fontLabel(_ state: FormatState?) -> String {
        let current = state?.font
        if let family = current.flatMap({ FontFamilies.family(of: $0) }) { return family }
        return state?.isFontMixed == true || current != nil ? "Mixed" : "Style Default"
    }

    private func toggle(_ symbol: String, _ title: String, shortcut: String, on: Bool?,
                        _ action: FormatAction) -> some View {
        Button { formatting.perform(action) } label: {
            Image(systemName: symbol)
                .fontWeight(.semibold)
                .frame(width: 24, height: 22)
                .background(on == true ? Crayon.tomato.opacity(0.2) : .clear, in: .rect(cornerRadius: 6))
        }
        .help("\(title) (\(shortcut))")
        .accessibilityLabel(title)
    }

    private func fontMenu(_ state: FormatState?) -> some View {
        Menu {
            Button("Style Default") { formatting.perform(.setFont(nil)) }
            Divider()
            ForEach(FontFamilies.all, id: \.self) { family in
                Button(family) {
                    if let face = FontFamilies.regularFace(of: family) { formatting.perform(.setFont(face)) }
                }
            }
        } label: {
            Text(Self.fontLabel(state))
                .frame(minWidth: 110, alignment: .leading)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Font")
    }

    private func alignmentPicker(_ current: BBModel.TextAlignment?) -> some View {
        Picker("Alignment", selection: Binding<BBModel.TextAlignment?>(
            get: { current },
            set: { formatting.perform(.setAlignment($0)) })) {
            ForEach(Self.alignments, id: \.title) { choice in
                Image(systemName: choice.symbol)
                    .accessibilityLabel(choice.title)
                    .tag(choice.value)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help(Self.alignmentHelp)
    }

    /// The alignment control's tooltip: every segment in order, with its shortcut.
    static var alignmentHelp: String {
        let parts = alignments.map { choice in choice.shortcut.map { "\(choice.title) (\($0))" } ?? choice.title }
        return "Alignment: " + parts.joined(separator: ", ")
    }

    private func colorBinding(_ color: RGBA?) -> Binding<Color> {
        // `color` is what the text is drawn with; black stands in only for a mixed selection.
        Binding(get: { (color ?? .black).swiftUIColor },
                set: { formatting.perform(.setColor(RGBA(color: $0))) })
    }
}

extension RGBA {
    var swiftUIColor: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }

    /// `color`'s sRGB components, or black if it has none.
    init(color: Color) {
        self = RichTextBridge.rgba(NSColor(color)) ?? .black
    }
}
