import AppKit
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
        .fixedSize(horizontal: false, vertical: true)
        .background(.bar)
        .accessibilityIdentifier("format-bar")
    }

    private var controls: some View {
        let state = formatting.state
        return HStack(spacing: 10) {
            HStack(spacing: 2) {
                toggle("bold", "Bold", on: state?.bold, .toggleBold)
                toggle("italic", "Italic", on: state?.italic, .toggleItalic)
                toggle("underline", "Underline", on: state?.underline, .toggleUnderline)
            }
            fontMenu(state?.font)
            HStack(spacing: 4) {
                Text(state?.size.map { String(format: "%g", $0) } ?? "–")
                    .monospacedDigit()
                    .frame(minWidth: 28)
                Stepper("Size", onIncrement: { formatting.perform(.biggerText) },
                        onDecrement: { formatting.perform(.smallerText) })
                    .labelsHidden()
            }
            .help("Text size")
            ColorPicker("Colour", selection: colorBinding(state?.color), supportsOpacity: false)
                .labelsHidden()
                .help("Text colour")
            Button { formatting.perform(.setColor(nil)) } label: { Image(systemName: "arrow.uturn.backward") }
                .help("Use the style's text colour")
            alignmentPicker(state?.alignment)
        }
        .buttonStyle(.borderless)
        .focusable(false)
        .disabled(!formatting.isEditing)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    private func toggle(_ symbol: String, _ title: String, on: Bool?, _ action: FormatAction) -> some View {
        Button { formatting.perform(action) } label: {
            Image(systemName: symbol)
                .frame(width: 24, height: 22)
                .background(on == true ? Color.accentColor.opacity(0.3) : .clear, in: .rect(cornerRadius: 4))
        }
        .help(title)
        .accessibilityLabel(title)
    }

    private func fontMenu(_ current: String?) -> some View {
        let family = current.flatMap { FontFamilies.family(of: $0) }
        return Menu {
            Button("Style default") { formatting.perform(.setFont(nil)) }
            Divider()
            ForEach(FontFamilies.all, id: \.self) { family in
                Button(family) {
                    if let face = FontFamilies.regularFace(of: family) { formatting.perform(.setFont(face)) }
                }
            }
        } label: {
            Text(family ?? (current == nil ? "Style default" : "Mixed"))
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
            Text("Style").tag(BBModel.TextAlignment?.none)
            Image(systemName: "text.alignleft").tag(BBModel.TextAlignment?.some(.leading))
            Image(systemName: "text.aligncenter").tag(BBModel.TextAlignment?.some(.center))
            Image(systemName: "text.alignright").tag(BBModel.TextAlignment?.some(.trailing))
            Image(systemName: "text.justify").tag(BBModel.TextAlignment?.some(.justified))
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("Alignment (Style = follow the style)")
    }

    private func colorBinding(_ color: RGBA?) -> Binding<Color> {
        Binding(get: { (color ?? .black).swiftUIColor },
                set: { formatting.perform(.setColor(RGBA(color: $0))) })
    }
}

extension RGBA {
    var swiftUIColor: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }

    init(color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        self.init(red: Double(ns.redComponent), green: Double(ns.greenComponent),
                  blue: Double(ns.blueComponent), alpha: Double(ns.alphaComponent))
    }
}
