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

/// Format ▸ Page Numbers… (PD §8.2): on/off, position, font and size, start number and the
/// skip rules. Edits a draft; Done applies it as one `setPageNumberStyle` (one undo step).
/// Specific pages are skipped from the page's context menu ("Skip Page Number").
struct PageNumbersSheet: View {
    let pages: PagesController
    @Environment(\.dismiss) private var dismiss
    @State private var draft: PageNumberStyle
    @State private var families: [String] = []

    static let sizeRange: ClosedRange<Double> = 6...72

    init(pages: PagesController, style: PageNumberStyle) {
        self.pages = pages
        _draft = State(initialValue: style)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Page Numbers").font(.headline)
            Form {
                Toggle("Show page numbers", isOn: $draft.enabled)
                Group {
                    Picker("Position", selection: $draft.position) {
                        ForEach(PageNumberPosition.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Picker("Font", selection: $draft.fontFamily) {
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
                        Text(draft.skippedPages.isEmpty ? "None" : "\(draft.skippedPages.count)")
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
            if let family = draft.fontFamily, !list.contains(family) { list.insert(family, at: 0) }
            families = list
        }
    }
}
