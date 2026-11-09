import AppKit
import BBExport
import BBLayout
import BBModel
import SwiftUI
import UniformTypeIdentifiers

extension FocusedValues {
    /// The book in the key book window (drives File ▸ Export… and Print…).
    @Entry public var focusedBook: BookDocument?
    /// Presents the typography form in the key book window (Format ▸ Typography…).
    @Entry var showTypography: Binding<Bool>?
    /// Presents the export sheet in the key book window (File ▸ Export…).
    @Entry var showExport: Binding<Bool>?
    /// The Pages tab's controller in the key book window (Page menu, Import Story Text…,
    /// Book Settings…, Page Numbers…).
    @Entry var pagesController: PagesController?
}

/// App menu commands: File ▸ New Book…, Import Story Text…, Export PDF… and Book Settings…;
/// the Page menu; Format ▸ Typography… and Page Numbers….
public struct BookBookCommands: Commands {
    private let app: AppModel
    @FocusedValue(\.focusedBook) private var book
    @FocusedValue(\.showTypography) private var showTypography
    @FocusedValue(\.showExport) private var showExport
    @FocusedValue(\.pagesController) private var pages
    @Environment(\.openWindow) private var openWindow

    public init(app: AppModel) {
        self.app = app
    }

    public var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Book…") {
                app.newBookRequested = true
                openWindow(id: SceneID.library)
            }
            .keyboardShortcut("n")
            Button("New Book from Story…") {
                app.newBookFromStoryRequested = true
                openWindow(id: SceneID.library)
            }
            Button("Open Sample Book") {
                Task { await app.openSampleBook { openWindow(value: $0) } }
            }
            Button("Library") { openWindow(id: SceneID.library) }
                .keyboardShortcut("l", modifiers: [.command, .shift])
        }
        CommandMenu("Format") {
            let editing = book?.formatting.isEditing ?? false
            let format = { (action: FormatAction) in book?.formatting.perform(action) }
            Button("Bold") { format(.toggleBold) }.keyboardShortcut("b").disabled(!editing)
            Button("Italic") { format(.toggleItalic) }.keyboardShortcut("i").disabled(!editing)
            Button("Underline") { format(.toggleUnderline) }.keyboardShortcut("u").disabled(!editing)
            Divider()
            Button("Bigger") { format(.biggerText) }.keyboardShortcut("+").disabled(!editing)
            Button("Smaller") { format(.smallerText) }.keyboardShortcut("-").disabled(!editing)
            Divider()
            Button("Align Left") { format(.setAlignment(.leading)) }.keyboardShortcut("{").disabled(!editing)
            Button("Center") { format(.setAlignment(.center)) }.keyboardShortcut("|").disabled(!editing)
            Button("Align Right") { format(.setAlignment(.trailing)) }.keyboardShortcut("}").disabled(!editing)
            Button("Style Default Alignment") { format(.setAlignment(nil)) }.disabled(!editing)
            Divider()
            Button("Typography…") { showTypography?.wrappedValue = true }
                .disabled(book?.isEditable != true)
            Button("Page Numbers…") { pages?.sheet = .pageNumbers }
                .disabled(pages?.isEditable != true)
        }
        CommandMenu("Page") { pageMenu }
        CommandGroup(after: .saveItem) {
            Button("Book Settings…") { pages?.sheet = .bookSettings }
                .keyboardShortcut(",", modifiers: [.command, .option])
                .disabled(pages?.isEditable != true)
        }
        CommandGroup(replacing: .importExport) {
            Button("Import Story Text…") { pages?.sheet = .importStory }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(pages?.isEditable != true)
            Button("Import from Book…") { pages?.sheet = .importFromBook }
                .disabled(pages?.isEditable != true)
            Button("Export…") { showExport?.wrappedValue = true }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(book == nil || showExport == nil)
            Button("Export Page as Image…") {
                if let book, let page = pages?.selectedPage ?? book.content.book.pageOrder.first {
                    ExportActions.exportPageAsImage(book, page: page)
                }
            }
            .disabled(book == nil || (pages?.selectedPage ?? book?.content.book.pageOrder.first) == nil)
        }
        CommandGroup(before: .help) {
            Button("Guided Setup…") { openWindow(id: OnboardingScene.id) }
        }
        CommandGroup(replacing: .printItem) {
            Button("Print…") { if let book { ExportActions.print(book) } }
                .keyboardShortcut("p")
                .disabled(book == nil)
        }
    }

    @ViewBuilder
    private var pageMenu: some View {
        let editable = pages?.isEditable == true
        let selected = pages?.selectedPage
        let story = pages?.isStoryPage(selected) == true
        Button("Show Overview") { pages?.mode = .overview }
            .keyboardShortcut("1", modifiers: [.command, .option])
            .disabled(pages == nil || pages?.mode == .overview)
        Button("Open in Editor") { if let selected { pages?.open(selected) } }
            .keyboardShortcut("2", modifiers: [.command, .option])
            .disabled(selected == nil || pages?.mode == .editor)
        Divider()
        Button("Add Page…") {
            if let pages { pages.sheet = .addPage(index: pages.insertionIndex) }
        }
        .keyboardShortcut("n", modifiers: [.command, .option])
        .disabled(!editable)
        Button("Duplicate Page") { if let selected { pages?.duplicate(selected) } }
            .keyboardShortcut("d")
            .disabled(!editable || !story)
        Button("Delete Page") { if let selected { pages?.delete(selected) } }
            .disabled(!editable || !story)
        Divider()
        Button(selected.map { pages?.isDone($0) == true } == true ? "Mark as Not Done" : "Mark as Done") {
            if let selected { pages?.toggleDone(selected) }
        }
        .disabled(!editable || selected == nil)
        Button("Change Layout…") { if let selected { pages?.sheet = .changeLayout(selected) } }
            .disabled(!editable || selected == nil)
        Button(selected.map { pages?.isNumberSkipped($0) == true } == true ? "Show Page Number" : "Skip Page Number") {
            if let selected { pages?.toggleSkipNumber(selected) }
        }
        .disabled(!editable || !story)
    }
}
