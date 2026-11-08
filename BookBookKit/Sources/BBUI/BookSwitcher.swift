import BBModel
import BBStore
import SwiftUI

/// The sidebar book switcher (PD §7): switch to another book (its own window), create,
/// duplicate or delete books. Book Settings comes in Phase 16.
struct BookSwitcher: View {
    let document: BookDocument
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @State private var actions = BookActionRequests()

    private var entry: LibraryEntry? { app.entry(for: document.id) }

    var body: some View {
        Menu {
            Section("Books") {
                ForEach(app.libraryEntries, id: \.url) { book in
                    Button {
                        openWindow(value: book.id)
                    } label: {
                        if book.id == document.id {
                            Label(book.title, systemImage: "checkmark")
                        } else {
                            Text(book.title)
                        }
                    }
                }
            }
            Divider()
            Button("New Book…") {
                app.newBookRequested = true
                openWindow(id: SceneID.library)
            }
            Button("Duplicate") { duplicate() }
                .disabled(entry == nil)
            Button("Move to Trash…") { actions.trashing = entry }
                .disabled(entry == nil)
            Divider()
            Button("Book Settings…") {}
                .disabled(true)
        } label: {
            Label(document.content.book.title, systemImage: "book.closed")
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .help("Switch, create, duplicate or delete books")
        .bookActions($actions)
    }

    private func duplicate() {
        guard let entry else { return }
        Task {
            do {
                let copy = try await app.duplicate(entry)
                openWindow(value: copy.id)
            } catch {
                actions.error = "Couldn't duplicate “\(entry.title)”. \(StoreErrorText.message(for: error))"
            }
        }
    }
}
