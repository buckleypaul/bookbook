import BBModel
import BBStore
import SwiftUI

/// A book window (A §6.1, §6.2). Opens the `BookDocument` through `AppModel` and flushes it
/// when the window closes.
public struct BookWindow: View {
    private let bookID: BookID
    @Environment(AppModel.self) private var app
    @State private var document: BookDocument?
    @State private var loadError: String?

    public init(bookID: BookID) {
        self.bookID = bookID
    }

    public var body: some View {
        Group {
            if let document {
                BookEditor(document: document)
            } else if let loadError {
                ContentUnavailableView("Couldn't Open the Book", systemImage: "exclamationmark.triangle",
                                       description: Text(loadError))
            } else {
                ProgressView("Opening…")
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .task(id: bookID) {
            do {
                document = try await app.openBook(bookID)
            } catch {
                loadError = StoreErrorText.message(for: error)
            }
        }
        .onDisappear {
            let app = app, bookID = bookID
            Task { await app.closeBook(bookID) }
        }
    }
}

/// The open book: page list, canvas and session panel.
struct BookEditor: View {
    let document: BookDocument
    @Environment(\.undoManager) private var undoManager
    @State private var selectedPage: PageID?
    @State private var selectedImageBox: BoxID?
    @State private var showSession = true
    @State private var images: ImageCache

    init(document: BookDocument) {
        self.document = document
        _images = State(initialValue: ImageCache(store: document.store))
    }

    var body: some View {
        let content = document.content
        NavigationSplitView {
            PageList(document: document, content: content, selection: $selectedPage)
                .navigationSplitViewColumnWidth(min: 160, ideal: 190, max: 260)
        } detail: {
            detail(content)
        }
        .inspector(isPresented: $showSession) {
            sessionPanel(content)
                .inspectorColumnWidth(min: 260, ideal: 320, max: 460)
        }
        .toolbar {
            ToolbarItem {
                Button { showSession.toggle() } label: { Label("Session", systemImage: "sidebar.trailing") }
                    .help("Show or hide the session panel")
            }
        }
        .navigationTitle(content.book.title)
        .focusedSceneValue(\.focusedBook, document)
        .onAppear {
            document.undoManager = undoManager
            if selectedPage == nil { selectedPage = content.book.pageOrder.first }
        }
        .onChange(of: undoManager) { _, manager in document.undoManager = manager }
        .onChange(of: content.book.pageOrder) { _, order in
            // An undo or redo can remove the selected page.
            if let page = selectedPage, !order.contains(page) { selectedPage = order.first }
        }
        .onChange(of: selectedPage) { selectedImageBox = nil }
    }

    @ViewBuilder
    private func detail(_ content: BookContent) -> some View {
        VStack(spacing: 0) {
            if let error = document.lastSaveError {
                Label("Couldn't save changes: \(StoreErrorText.message(for: error))", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .padding(8)
                    .frame(maxWidth: .infinity)
                    .background(.yellow.opacity(0.25))
            }
            if let page = selectedPage, content.pages[page] != nil {
                PageCanvas(document: document, content: content, pageID: page, imageSource: images,
                           selectedImageBox: $selectedImageBox)
            } else {
                ContentUnavailableView("No Page Selected", systemImage: "doc",
                                       description: Text("Choose a page, or add one with +."))
            }
        }
    }

    @ViewBuilder
    private func sessionPanel(_ content: BookContent) -> some View {
        if let page = selectedPage, let box = selectedImageBox, content.pages[page]?.images[box] != nil {
            SessionPanel(document: document, content: content, pageID: page, boxID: box, images: images)
                .id(box)
        } else {
            ContentUnavailableView("No Image Box Selected", systemImage: "photo",
                                   description: Text("Click an image box on the page to see its session."))
        }
    }
}

/// The page list: story pages in reading order, with add and delete (both undoable).
struct PageList: View {
    let document: BookDocument
    let content: BookContent
    @Binding var selection: PageID?

    var body: some View {
        List(selection: $selection) {
            ForEach(PageListing.items(content)) { item in
                HStack {
                    Text(item.title)
                    Spacer()
                    Text(item.statusText).font(.caption).foregroundStyle(.secondary)
                }
                .tag(item.id)
            }
        }
        .onDeleteCommand(perform: deleteSelected)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 2) {
                Button(action: addPage) { Image(systemName: "plus") }
                    .help("Add a page after the selected one")
                    .disabled(PageListing.storyTemplateID(in: content) == nil)
                Button(action: deleteSelected) { Image(systemName: "minus") }
                    .help("Delete the selected page")
                    .disabled(selection == nil)
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
    }

    private func addPage() {
        guard let templateID = PageListing.storyTemplateID(in: content) else { return }
        let index = PageListing.insertionIndex(after: selection, in: content)
        guard document.perform(.addPage(index: index, templateID: templateID)) else { return }
        let order = document.content.book.pageOrder
        if order.indices.contains(index) { selection = order[index] }
    }

    private func deleteSelected() {
        guard let page = selection else { return }
        let next = PageListing.selectionAfterDeleting(page, in: content)
        if document.perform(.deletePage(page)) { selection = next }
    }
}
