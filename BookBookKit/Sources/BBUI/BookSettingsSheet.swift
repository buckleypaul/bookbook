import BBModel
import BBStore
import SwiftUI

/// Book Settings (PD §8.12, Phase 5 minimum): the title and author shown on the cover and the
/// title page. Neither is undoable (PD §8.10): the title goes through `AppModel.rename` (so the
/// library updates) and the author through `BookDocument.setAuthor`.
struct BookSettingsSheet: View {
    let document: BookDocument
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var author: String
    @State private var error: String?
    @State private var saving = false

    init(document: BookDocument) {
        self.document = document
        _title = State(initialValue: document.content.book.title)
        _author = State(initialValue: document.content.book.author)
    }

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Book Settings").font(.headline)
            Form {
                TextField("Title", text: $title)
                TextField("Author", text: $author)
            }
            .disabled(!document.isEditable)
            Text("The title and author appear on the cover and the title page.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!document.isEditable || trimmedTitle.isEmpty || saving)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func save() {
        let book = document.content.book
        let newAuthor = author.trimmingCharacters(in: .whitespacesAndNewlines)
        if newAuthor != book.author, !document.setAuthor(newAuthor) {
            error = "Couldn't change the author."
            return
        }
        guard trimmedTitle != book.title else {
            dismiss()
            return
        }
        guard let entry = app.entry(for: document.id) else {
            // Not in the library index (yet): set it on the open book directly.
            if document.rename(to: trimmedTitle) { dismiss() } else { error = "Couldn't change the title." }
            return
        }
        saving = true
        let title = trimmedTitle
        Task {
            defer { saving = false }
            do {
                try await app.rename(entry, to: title)
                dismiss()
            } catch {
                self.error = "Couldn't change the title. \(StoreErrorText.message(for: error))"
            }
        }
    }
}
