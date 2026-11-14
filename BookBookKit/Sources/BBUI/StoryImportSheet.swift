import AppKit
import BBLayout
import BBModel
import BBStore
import SwiftUI
import UniformTypeIdentifiers

/// The story-import sheet's state (PD §8.5): the text (pasted, or read from a file), the split
/// rule and the template; `pages` is the preview. Not a view, so it's testable.
@MainActor @Observable
final class StoryImportModel {
    enum Rule: Hashable, CaseIterable {
        case blankLines, marker
        var title: String { self == .blankLines ? "Blank lines" : "Marker" }
    }

    static let defaultMarker = "---"

    /// Pasted text. Typing here replaces a file that was opened.
    var pastedText = "" {
        didSet { if pastedText != oldValue, !settingFromFile { file = nil } }
    }
    /// Text read from a `.txt`/`.rtf` file (keeps RTF formatting), with its file name.
    private(set) var file: (name: String, text: RichText)?
    var rule: Rule = .blankLines
    var marker = StoryImportModel.defaultMarker
    var templateID: TemplateID?
    var readError: String?
    @ObservationIgnored private var settingFromFile = false

    init(templateID: TemplateID?) {
        self.templateID = templateID
    }

    var fileName: String? { file?.name }

    /// The rule for `StoryTextImporter.split`. An empty marker falls back to `---`.
    var splitRule: StorySplitRule {
        switch rule {
        case .blankLines: return .blankLines
        case .marker:
            let trimmed = marker.trimmingCharacters(in: .whitespacesAndNewlines)
            return .marker(trimmed.isEmpty ? Self.defaultMarker : trimmed)
        }
    }

    var source: RichText { file?.text ?? StoryTextImporter.richText(fromPlain: pastedText) }

    /// The pages the import would create.
    var pages: [RichText] { StoryTextImporter.split(source, rule: splitRule) }

    var canImport: Bool { templateID != nil && !pages.isEmpty }

    /// Loads a file; on failure keeps the current text and sets `readError`.
    func open(_ url: URL, typography: Typography) {
        do {
            let text = try StoryTextImporter.read(url, typography: typography)
            settingFromFile = true
            pastedText = text.plainText
            settingFromFile = false
            file = (url.lastPathComponent, text)
            readError = nil
        } catch {
            readError = switch error {
            case .unsupportedType: "BookBook can import plain text (.txt, .text, .md) or rich text (.rtf) files."
            case .unreadable: "Couldn't read “\(url.lastPathComponent)”."
            }
        }
    }

    /// One line of preview for a page.
    static func previewLine(_ text: RichText) -> String {
        text.plainText.split(whereSeparator: \.isNewline).joined(separator: " ")
    }
}

/// File ▸ Import Story Text… (PD §8.5): paste or open a text file, choose how to split it and
/// a template, check the preview, then import after the selected page as one undo step.
struct StoryImportSheet: View {
    let document: BookDocument
    let pages: PagesController
    @State private var model: StoryImportModel
    @FocusState private var editorFocused: Bool

    init(document: BookDocument, pages: PagesController) {
        self.document = document
        self.pages = pages
        let choices = Self.templates(document.content)
        let preferred = choices.first { $0.id == Presets.storyTemplateID } ?? choices.first
        _model = State(initialValue: StoryImportModel(templateID: preferred?.id))
    }

    static func templates(_ content: BookContent) -> [Template] {
        PagesOverviewModel.templateChoices(forCover: false, in: content, presets: Presets.bundledTemplates)
    }

    var body: some View {
        @Bindable var model = model
        let content = document.content
        let preview = model.pages
        VStack(alignment: .leading, spacing: 12) {
            CrayonHeader("Import Story Text", color: Crayon.sky)
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(model.fileName.map { "From “\($0)”" } ?? "Paste the story, or open a file.")
                            .font(.callout)
                            .foregroundStyle(Crayon.inkSoft)
                            .lineLimit(1)
                        Spacer()
                        Button("Open…", action: openFile)
                    }
                    TextEditor(text: $model.pastedText)
                        .focused($editorFocused)
                        .crayonTextEditor(focused: editorFocused, minHeight: 200)
                        .accessibilityLabel("Story text")
                    if let error = model.readError {
                        CrayonInlineMessage(error, kind: .warning, textStyle: .callout)
                    }
                    Form {
                        Picker("Split pages at", selection: $model.rule) {
                            ForEach(StoryImportModel.Rule.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        if model.rule == .marker {
                            TextField("Marker line", text: $model.marker, prompt: Text(StoryImportModel.defaultMarker))
                        }
                    }
                    .formStyle(.columns)
                }
                .frame(minWidth: 320)
                VStack(alignment: .leading, spacing: 8) {
                    Text(preview.count == 1 ? "1 page" : "\(preview.count) pages")
                        .font(Crayon.font(.callout, weight: .bold))
                    List(Array(preview.enumerated()), id: \.offset) { index, page in
                        HStack(alignment: .firstTextBaseline) {
                            Text("\(index + 1)")
                                .font(Crayon.font(.callout, weight: .heavy))
                                .monospacedDigit()
                                .foregroundStyle(Crayon.danger)
                            Text(StoryImportModel.previewLine(page)).lineLimit(2)
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .crayonCard(cornerRadius: Crayon.smallCornerRadius)
                    .frame(minHeight: 200)
                }
                .frame(minWidth: 260)
            }
            Text("Template").font(Crayon.font(.callout, weight: .bold))
            TemplatePicker(templates: Self.templates(content), trimSize: content.style.pageSetup.trimSize,
                           selection: $model.templateID)
                .frame(height: 180)
            CrayonSheetFooter("Import", color: Crayon.sky, isDisabled: !model.canImport || !document.isEditable) {
                importPages(preview)
            } leading: {
                Text(pages.isStoryPage(pages.selectedPage) || pages.isCover(pages.selectedPage)
                     ? "Pages are inserted after the selected page." : "Pages are added at the end.")
                    .font(.caption)
                    .foregroundStyle(Crayon.inkSoft)
            }
        }
        .crayonSheet(minWidth: 700, minHeight: 560)
    }

    /// The file types the open panel offers: the importer's plain-text and rich-text
    /// extensions (Phase 16b #71a). `.rtfd` is not read (v1.x).
    static var allowedContentTypes: [UTType] {
        var types: [UTType] = [.plainText, .rtf]
        let extensions = StoryTextImporter.plainTextExtensions.union(StoryTextImporter.richTextExtensions).sorted()
        for name in extensions {
            if let type = UTType(filenameExtension: name), !types.contains(type) { types.append(type) }
        }
        return types
    }

    private func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.allowedContentTypes
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.open(url, typography: document.content.style.typography)
    }

    private func importPages(_ texts: [RichText]) {
        guard let templateID = model.templateID, !texts.isEmpty else { return }
        pages.dismissSheet { [pages] in pages.importStory(texts, templateID: templateID) }
    }
}
