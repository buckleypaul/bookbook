import AppKit
import BBExport
import BBModel
import SwiftUI
import UniformTypeIdentifiers

extension FocusedValues {
    /// The book in the key book window (drives File ▸ Export PDF…).
    @Entry public var focusedBook: BookDocument?
    /// Presents the typography form in the key book window (Format ▸ Typography…).
    @Entry var showTypography: Binding<Bool>?
}

/// App menu commands: File ▸ New Book… and File ▸ Export PDF….
public struct BookBookCommands: Commands {
    private let app: AppModel
    @FocusedValue(\.focusedBook) private var book
    @FocusedValue(\.showTypography) private var showTypography
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
        }
        CommandGroup(replacing: .importExport) {
            Button("Export PDF…") {
                if let book { PDFExportAction.run(book) }
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(book == nil)
        }
    }
}

/// File ▸ Export PDF… (Standard): a save panel, then `PDFExporter` with full-resolution images.
@MainActor
enum PDFExportAction {
    static func run(_ document: BookDocument) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = defaultFileName(title: document.content.book.title)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try PDFExporter.exportStandard(document.content, images: ImageCache(store: document.store, maxPixelSize: nil),
                                           to: url)
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Couldn't export the PDF"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    /// `<title>.pdf`, with path separators replaced.
    static func defaultFileName(title: String) -> String {
        var name = title.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        if name.isEmpty { name = "Untitled" }
        return name + ".pdf"
    }
}
