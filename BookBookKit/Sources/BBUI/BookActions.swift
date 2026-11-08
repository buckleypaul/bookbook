import BBModel
import BBStore
import SwiftUI

/// Library actions that need a sheet or a confirmation, shared by the Library window and the
/// book switcher: Rename… (sheet), Move to Trash… (confirmation) and errors.
struct BookActionRequests {
    var renaming: LibraryEntry?
    var trashing: LibraryEntry?
    var error: String?
}

extension View {
    func bookActions(_ requests: Binding<BookActionRequests>) -> some View {
        modifier(BookActionsModifier(requests: requests))
    }
}

private struct BookActionsModifier: ViewModifier {
    @Binding var requests: BookActionRequests
    @Environment(AppModel.self) private var app

    func body(content: Content) -> some View {
        content
            .sheet(item: $requests.renaming) { entry in
                RenameBookSheet(entry: entry)
            }
            .alert(
                "Move “\(requests.trashing?.title ?? "")” to the Trash?",
                isPresented: Binding(get: { requests.trashing != nil }, set: { if !$0 { requests.trashing = nil } }),
                presenting: requests.trashing
            ) { entry in
                Button("Move to Trash", role: .destructive) { trash(entry) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("The book goes to the Trash, and its window closes if it's open. You can put it back from the Trash in the Finder; this can't be undone in BookBook.")
            }
            .alert(
                "Something Went Wrong",
                isPresented: Binding(get: { requests.error != nil }, set: { if !$0 { requests.error = nil } }),
                presenting: requests.error
            ) { _ in
                Button("OK") {}
            } message: { text in
                Text(text)
            }
    }

    private func trash(_ entry: LibraryEntry) {
        requests.trashing = nil
        Task {
            do {
                try await app.trash(entry)
            } catch {
                requests.error = ("Couldn't move “\(entry.title)” to the Trash. \(StoreErrorText.message(for: error))")
            }
        }
    }
}

/// Renames a book (its title; the file keeps its name).
struct RenameBookSheet: View {
    let entry: LibraryEntry
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var error: String?
    @State private var working = false

    init(entry: LibraryEntry) {
        self.entry = entry
        _title = State(initialValue: entry.title)
    }

    private var trimmed: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        Form {
            TextField("Title", text: $title)
                .onSubmit(rename)
            if let error {
                Text(error).foregroundStyle(.red).font(.callout)
            }
        }
        .formStyle(.grouped)
        .frame(width: 360)
        .navigationTitle("Rename Book")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Rename", action: rename)
                    .disabled(working || trimmed.isEmpty)
            }
        }
    }

    private func rename() {
        guard !trimmed.isEmpty, !working else { return }
        if trimmed == entry.title {
            dismiss()
            return
        }
        working = true
        Task {
            defer { working = false }
            do {
                try await app.rename(entry, to: trimmed)
                dismiss()
            } catch {
                self.error = "Couldn't rename the book. \(StoreErrorText.message(for: error))"
            }
        }
    }
}
