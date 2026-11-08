import AppKit
import BBModel
import SwiftUI

extension PageNumberPosition {
    var title: String {
        switch self {
        case .bottomCenter: "Bottom centre"
        case .bottomOuter: "Bottom outer corner"
        case .bottomInner: "Bottom inner corner"
        case .topCenter: "Top centre"
        case .topOuter: "Top outer corner"
        case .topInner: "Top inner corner"
        }
    }
}

/// Maps between the family names the picker shows and the PostScript names
/// `PageNumberStyle.fontFamily` stores (drawing resolves fonts by PostScript name).
enum PageNumberFontNames {
    /// PostScript name of the family's regular face (else its first face); nil if unavailable.
    static func postScriptName(forFamily family: String) -> String? {
        let members = NSFontManager.shared.availableMembers(ofFontFamily: family) ?? []
        // Each member is [postScriptName, styleName, weight, traits].
        let faces = members.compactMap { m -> (ps: String, style: String)? in
            guard m.count >= 2, let ps = m[0] as? String, let style = m[1] as? String else { return nil }
            return (ps, style)
        }
        let regular = faces.first { ["Regular", "Roman", "Book", "Normal", "Medium"].contains($0.style) }
        return (regular ?? faces.first)?.ps
    }

    /// Display family for a stored PostScript name; nil when the font isn't installed.
    static func family(forPostScriptName name: String) -> String? {
        NSFont(name: name, size: 12)?.familyName
    }
}

/// Format ▸ Page Numbers… (PD §8.2): on/off, position, font and size, start number and the
/// skip rules. Edits a draft; Done applies it as one `setPageNumberStyle` (one undo step).
/// Specific pages are skipped from the page's context menu ("Skip Page Number").
struct PageNumbersSheet: View {
    let pages: PagesController
    @Environment(\.dismiss) private var dismiss
    @State private var draft: PageNumberStyle
    @State private var families: [String] = []
    /// Family chosen in the picker; nil is the body font. Stored as a PostScript name on Done.
    @State private var family: String?

    /// The book when the sheet opened, for counting skipped pages (front matter needs each
    /// page's template role). Without it only individually skipped pages are counted.
    let content: BookContent?
    /// The family the picker showed on open; unchanged means the stored face stays as it was.
    private let initialFamily: String?

    static let sizeRange: ClosedRange<Double> = 6...72

    init(pages: PagesController, style: PageNumberStyle, content: BookContent? = nil) {
        self.pages = pages
        self.content = content
        initialFamily = style.fontFamily.map { PageNumberFontNames.family(forPostScriptName: $0) ?? $0 }
        _draft = State(initialValue: style)
        _family = State(initialValue: style.fontFamily.map { PageNumberFontNames.family(forPostScriptName: $0) ?? $0 })
    }

    /// Pages without a number: individually skipped ones that still exist, plus front matter
    /// when that rule is on. The cover and deleted pages never count.
    static func skippedCount(style: PageNumberStyle, content: BookContent?, isStoryPage: (PageID) -> Bool) -> Int {
        guard let content else { return style.skippedPages.filter(isStoryPage).count }
        return content.storyPages.filter { page in
            style.skippedPages.contains(page.id)
                || (style.skipFrontMatter && content.template(for: page)?.pageRole?.isFrontMatter == true)
        }.count
    }

    var body: some View {
        let skipped = Self.skippedCount(style: draft, content: content, isStoryPage: { pages.isStoryPage($0) })
        VStack(alignment: .leading, spacing: 12) {
            Text("Page Numbers").font(.headline)
            Form {
                Toggle("Show page numbers", isOn: $draft.enabled)
                Group {
                    Picker("Position", selection: $draft.position) {
                        ForEach(PageNumberPosition.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Picker("Font", selection: $family) {
                        Text("Body font").tag(String?.none)
                        Divider()
                        ForEach(families, id: \.self) { Text($0).tag(String?.some($0)) }
                    }
                    LabeledContent("Size") {
                        HStack {
                            TextField("Size", value: $draft.size, format: .number.precision(.fractionLength(0...1)))
                                .frame(width: 60)
                                .labelsHidden()
                            Stepper("Size", value: $draft.size, in: Self.sizeRange, step: 1).labelsHidden()
                            Text("pt").foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent("Start at") {
                        HStack {
                            TextField("Start at", value: $draft.startNumber, format: .number)
                                .frame(width: 60)
                                .labelsHidden()
                            Stepper("Start at", value: $draft.startNumber, in: 0...9999).labelsHidden()
                        }
                    }
                    Toggle("Skip front-matter pages (title, dedication, belongs to)", isOn: $draft.skipFrontMatter)
                    LabeledContent("Pages skipped") {
                        Text(skipped == 0 ? "None" : "\(skipped)")
                    }
                }
                .disabled(!draft.enabled)
            }
            Text("The cover is never numbered. Numbers follow the printed position: page 1 is the first right-hand page after the cover. To skip one page, right-click it and choose Skip Page Number.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if !draft.skippedPages.isEmpty {
                    Button("Number All Pages") { draft.skippedPages = [] }
                        .disabled(!draft.enabled)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Done") {
                    var style = draft
                    if family == initialFamily {
                        // Untouched: keep the stored face (e.g. a bold one) as it was.
                        style.fontFamily = draft.fontFamily
                    } else if let family {
                        style.fontFamily = PageNumberFontNames.postScriptName(forFamily: family)
                            ?? (family == draft.fontFamily ? draft.fontFamily : nil)
                    } else {
                        style.fontFamily = nil
                    }
                    style.size = min(max(style.size, Self.sizeRange.lowerBound), Self.sizeRange.upperBound)
                    style.startNumber = max(0, style.startNumber)
                    pages.setPageNumberStyle(style)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!pages.isEditable)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            var list = NSFontManager.shared.availableFontFamilies
            // Keep a family the style names even if it isn't installed.
            if let family, !list.contains(family) { list.insert(family, at: 0) }
            families = list
        }
    }
}
