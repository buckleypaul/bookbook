import BBModel
import BBStore
import SwiftUI

/// The Library window (A §6.1; Phase 2: a folder scan plus New Book).
public struct LibraryView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @State private var selection: BookID?

    public init() {}

    public var body: some View {
        @Bindable var app = app
        Group {
            if app.libraryEntries.isEmpty {
                ContentUnavailableView {
                    Label("No Books Yet", systemImage: "books.vertical")
                } description: {
                    Text("Your books will appear here.")
                } actions: {
                    Button("New Book…") { app.newBookRequested = true }
                }
            } else {
                List(app.libraryEntries, selection: $selection) { entry in
                    HStack {
                        Label(entry.title, systemImage: "book.closed")
                        Spacer()
                        Text(entry.modifiedAt, format: .dateTime.day().month().year().hour().minute())
                            .foregroundStyle(.secondary)
                    }
                    .tag(entry.id)
                }
                .contextMenu(forSelectionType: BookID.self) { ids in
                    if let id = ids.first {
                        Button("Open") { openWindow(value: id) }
                    }
                } primaryAction: { ids in
                    for id in ids { openWindow(value: id) }
                }
            }
        }
        .frame(minWidth: 480, minHeight: 320)
        .toolbar {
            ToolbarItemGroup {
                Button { app.newBookRequested = true } label: { Label("New Book…", systemImage: "plus") }
                    .help("Create a new book")
                Button { if let selection { openWindow(value: selection) } } label: {
                    Label("Open", systemImage: "arrow.up.forward.square")
                }
                .help("Open the selected book")
                .disabled(selection == nil)
            }
        }
        .sheet(isPresented: $app.newBookRequested) {
            NewBookSheet { id in openWindow(value: id) }
        }
        .task { await app.refreshLibrary() }
    }
}

/// Asks for a title, creates the book and opens it.
struct NewBookSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var title = "Untitled"
    @State private var error: String?
    @State private var creating = false
    let onCreated: (BookID) -> Void

    var body: some View {
        Form {
            TextField("Title", text: $title)
            if let error {
                Text(error).foregroundStyle(.red).font(.callout)
            }
        }
        .formStyle(.grouped)
        .frame(width: 360)
        .navigationTitle("New Book")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Create") { create() }
                    .disabled(creating)
            }
        }
    }

    private func create() {
        creating = true
        Task {
            defer { creating = false }
            do {
                let entry = try await app.createBook(title: title)
                dismiss()
                onCreated(entry.id)
            } catch {
                self.error = "Couldn't create the book. \(StoreErrorText.message(for: error))"
            }
        }
    }
}
