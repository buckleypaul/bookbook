import AppKit
import BBModel
import BBStore
import SwiftUI

/// The Library window (A §6.1, PD §8.1): a grid of books with cover thumbnails and modified dates.
/// Open, Rename…, Duplicate, Move to Trash and Show in Finder from the context menu and toolbar.
public struct LibraryView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @State private var selection: BookID?
    @State private var actions = BookActionRequests()

    public init() {}

    private var selectedEntry: LibraryEntry? { selection.flatMap { app.entry(for: $0) } }

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
                    Button("New Book from Story…") { app.newBookFromStoryRequested = true }
                }
            } else {
                grid
            }
        }
        .frame(minWidth: 520, minHeight: 360)
        .safeAreaInset(edge: .top, spacing: 0) {
            if case .restored = app.queueSnapshot.pause { QueueResumeBanner(pause: app.queueSnapshot.pause) }
        }
        .toolbar {
            ToolbarItemGroup {
                Button { app.newBookRequested = true } label: { Label("New Book…", systemImage: "plus") }
                    .help("Create a new book")
                Button { app.newBookFromStoryRequested = true } label: {
                    Label("New Book from Story…", systemImage: "text.book.closed")
                }
                .help("Create a new book and import its story text")
                Button { if let selection { openWindow(value: selection) } } label: {
                    Label("Open", systemImage: "arrow.up.forward.square")
                }
                .help("Open the selected book")
                .disabled(selection == nil)
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([app.libraryRoot])
                } label: {
                    Label("Show Library in Finder", systemImage: "folder")
                }
                .help("Show the library folder in the Finder")
            }
        }
        .sheet(isPresented: $app.newBookRequested) {
            NewBookSheet { id in openWindow(value: id) }
        }
        .sheet(isPresented: $app.newBookFromStoryRequested) {
            NewBookSheet(fromStory: true) { id in openWindow(value: id) }
        }
        .bookActions($actions)
        .task {
            await app.start()
            await app.reopenBooks { openWindow(value: $0) }
        }
        .onChange(of: app.libraryEntries) { _, entries in
            if let id = selection, !entries.contains(where: { $0.id == id }) { selection = nil }
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 210), spacing: 20)], spacing: 24) {
                // Keyed by URL: two packages can carry the same book ID (a Finder copy).
                ForEach(app.libraryEntries, id: \.url) { entry in
                    LibraryCell(entry: entry, isSelected: selection == entry.id)
                        .onTapGesture(count: 2) { openWindow(value: entry.id) }
                        .simultaneousGesture(TapGesture().onEnded { selection = entry.id })
                        .contextMenu { menu(for: entry) }
                }
            }
            .padding(20)
        }
        .contentShape(Rectangle())
        .onTapGesture { selection = nil }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.return) {
            guard let selection else { return .ignored }
            openWindow(value: selection)
            return .handled
        }
        .onDeleteCommand { actions.trashing = selectedEntry }
    }

    @ViewBuilder
    private func menu(for entry: LibraryEntry) -> some View {
        Button("Open") { openWindow(value: entry.id) }
        Divider()
        Button("Rename…") { actions.renaming = entry }
        Button("Duplicate") { duplicate(entry) }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
        Divider()
        Button("Move to Trash…", role: .destructive) { actions.trashing = entry }
    }

    private func duplicate(_ entry: LibraryEntry) {
        Task {
            do {
                selection = try await app.duplicate(entry).id
            } catch {
                actions.error = "Couldn't duplicate “\(entry.title)”. \(StoreErrorText.message(for: error))"
            }
        }
    }
}

/// One book in the grid: its thumbnail (or a placeholder), title and modified date.
struct LibraryCell: View {
    let entry: LibraryEntry
    let isSelected: Bool
    @Environment(AppModel.self) private var app
    @State private var image: NSImage?

    private struct ThumbnailKey: Hashable {
        var url: URL?
        var modifiedAt: Date
    }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .shadow(radius: 2, y: 1)
                } else {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.quaternary)
                        .aspectRatio(3 / 4, contentMode: .fit)
                        .overlay {
                            Image(systemName: "book.closed").font(.largeTitle).foregroundStyle(.secondary)
                        }
                }
            }
            .frame(height: 180)
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 8).fill(isSelected ? Color.accentColor.opacity(0.25) : .clear))
            Text(entry.title)
                .font(.callout.weight(.medium))
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Text(entry.modifiedAt, format: .dateTime.day().month().year().hour().minute())
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .task(id: ThumbnailKey(url: entry.thumbnailURL, modifiedAt: entry.modifiedAt)) {
            guard let source = entry.thumbnailURL else {
                image = nil
                return
            }
            let rendition = await app.thumbnails.rendition(of: source, bookID: entry.id, maxPixelSize: 400)
            // Read the bytes (not `NSImage(contentsOf:)`) so a rewritten file isn't served from a cache.
            image = rendition.flatMap { try? Data(contentsOf: $0) }.flatMap { NSImage(data: $0) }
        }
    }
}

/// Asks for a title, creates the book and opens it.
struct NewBookSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var title = "Untitled"
    @State private var error: String?
    @State private var creating = false
    /// Open the new book with the Import Story Text sheet up. Cancelling that sheet leaves the
    /// new, empty book.
    var fromStory = false
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
        .navigationTitle(fromStory ? "New Book from Story" : "New Book")
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
                let entry = try await app.createBook(title: title, thenImportStory: fromStory)
                dismiss()
                onCreated(entry.id)
            } catch {
                self.error = "Couldn't create the book. \(StoreErrorText.message(for: error))"
            }
        }
    }
}
