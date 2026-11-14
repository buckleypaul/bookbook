import AppKit
import BBModel
import SwiftUI

extension PageNumberPosition {
    var title: String {
        switch self {
        case .bottomCenter: "Bottom Centre"
        case .bottomOuter: "Bottom Outer Corner"
        case .bottomInner: "Bottom Inner Corner"
        case .topCenter: "Top Centre"
        case .topOuter: "Top Outer Corner"
        case .topInner: "Top Inner Corner"
        }
    }
}

/// Maps a family the picker shows to the PostScript name `PageNumberStyle.fontFamily` stores
/// (drawing resolves fonts by PostScript name). The reverse is `FontFamilies.family(of:)`.
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
    /// What the size and start-number fields show. `TextField(value:format:)` only commits on
    /// Return or focus loss, so a number typed just before clicking Done would be lost.
    @State private var sizeText: String
    @State private var startText: String

    /// The book when the sheet opened, for counting skipped pages (front matter needs each
    /// page's template role). Without it only individually skipped pages are counted.
    let content: BookContent?
    /// The family the picker showed on open; unchanged means the stored face stays as it was.
    private let initialFamily: String?

    /// The `fontFamily` Done stores. Untouched keeps the stored face (e.g. a bold one); a new
    /// family is stored as its PostScript name; nil is the body font.
    static func resolvedFont(family: String?, initialFamily: String?, stored: String?) -> String? {
        if family == initialFamily { return stored }
        guard let family else { return nil }
        return PageNumberFontNames.postScriptName(forFamily: family) ?? (family == stored ? stored : nil)
    }

    static let sizeRange: ClosedRange<Double> = 6...72

    static func formatSize(_ size: Double) -> String {
        size.formatted(.number.precision(.fractionLength(0...1)).grouping(.never))
    }

    init(pages: PagesController, style: PageNumberStyle, content: BookContent? = nil) {
        self.pages = pages
        self.content = content
        let initialFamily = style.fontFamily.map { FontFamilies.family(of: $0) ?? $0 }
        self.initialFamily = initialFamily
        _draft = State(initialValue: style)
        _family = State(initialValue: initialFamily)
        _sizeText = State(initialValue: Self.formatSize(style.size))
        _startText = State(initialValue: String(style.startNumber))
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
            CrayonHeader("Page Numbers", color: Crayon.sky)
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
                            TextField("Size", text: $sizeText)
                                .frame(width: 60)
                                .labelsHidden()
                                .onChange(of: sizeText) { _, text in
                                    if let v = Double(text.trimmingCharacters(in: .whitespaces)), v.isFinite { draft.size = v }
                                }
                                .onChange(of: draft.size) { _, size in
                                    if Double(sizeText.trimmingCharacters(in: .whitespaces)) != size { sizeText = Self.formatSize(size) }
                                }
                            Stepper("Size", value: $draft.size, in: Self.sizeRange, step: 1).labelsHidden()
                            Text("pt").foregroundStyle(Crayon.inkSoft)
                        }
                    }
                    LabeledContent("Start at") {
                        HStack {
                            TextField("Start at", text: $startText)
                                .frame(width: 60)
                                .labelsHidden()
                                .onChange(of: startText) { _, text in
                                    if let v = Int(text.trimmingCharacters(in: .whitespaces)) { draft.startNumber = v }
                                }
                                .onChange(of: draft.startNumber) { _, n in
                                    if Int(startText.trimmingCharacters(in: .whitespaces)) != n { startText = String(n) }
                                }
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
            .disabled(!pages.isEditable)
            Text("The cover is never numbered. Numbers follow the printed position: page 1 is the first right-hand page after the cover. To skip one page, right-click it and choose Skip Page Number.")
                .font(.caption)
                .foregroundStyle(Crayon.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            if pages.isEditable {
                CrayonSheetFooter("Done", color: Crayon.sky, action: done, leading: { numberAllButton })
            } else {
                CrayonSheetDoneFooter(color: Crayon.sky, leading: { numberAllButton })
            }
        }
        .crayonSheet(width: 460)
        .onExitCommand { dismiss() }
        .onAppear {
            var list = FontFamilies.all
            // Keep a family the style names even if it isn't installed.
            if let family, !list.contains(family) { list.insert(family, at: 0) }
            families = list
        }
    }

    @ViewBuilder
    private var numberAllButton: some View {
        if !draft.skippedPages.isEmpty {
            Button("Number All Pages") { draft.skippedPages = [] }
                .disabled(!draft.enabled || !pages.isEditable)
        }
    }

    private func done() {
        var style = draft
        style.fontFamily = Self.resolvedFont(family: family, initialFamily: initialFamily,
                                             stored: draft.fontFamily)
        style.size = min(max(style.size, Self.sizeRange.lowerBound), Self.sizeRange.upperBound)
        style.startNumber = max(0, style.startNumber)
        pages.setPageNumberStyle(style)
        dismiss()
    }
}
