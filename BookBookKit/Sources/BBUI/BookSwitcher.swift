import BBModel
import BBStore
import SwiftUI

/// The sidebar book switcher (PD §7): switch to another book (its own window), create,
/// duplicate or delete books, and open Book Settings.
struct BookSwitcher: View {
    let document: BookDocument
    /// Opens the Book Settings sheet (the window's `PagesController`).
    var onBookSettings: () -> Void = {}
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
                app.newBookRequest = .blank
                openWindow(id: SceneID.library)
            }
            Button("Duplicate") { duplicate() }
                .disabled(entry == nil)
            Button("Move to Trash…") { actions.trashing = entry }
                .disabled(entry == nil)
            Divider()
            Button("Book Settings…", action: onBookSettings)
                .disabled(!document.isEditable)
        } label: {
            Label {
                Text(document.content.book.title)
                    .font(Crayon.font(.callout, weight: .bold))
                    .foregroundStyle(Crayon.ink)
            } icon: {
                Image(systemName: "book.closed.fill")
                    .foregroundStyle(Crayon.color(forKey: document.id.rawValue.uuidString))
            }
            .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .crayonCard(cornerRadius: Crayon.smallCornerRadius)
        .crayonHover(tilt: -1, scale: 1.02)
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
