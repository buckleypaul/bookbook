import BBModel
import BBStore
import SwiftUI

/// A book window (A §6.1, §6.2). Opens the `BookDocument` through `AppModel` (taking the book's
/// lock, or offering read-only if another BookBook holds it) and closes it (flush, release the
/// lock) when the window closes. The first window to appear also reopens the books that were
/// open at quit.
public struct BookWindow: View {
    private let bookID: BookID
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @State private var document: BookDocument?
    @State private var loadError: String?
    @State private var lockOwner: LockOwner?
    @State private var showLockAlert = false

    public init(bookID: BookID) {
        self.bookID = bookID
    }

    /// The window's minimum width. It must not be less than the editor's own minimum: an explicit
    /// `frame(minWidth:)` replaces the content's minimum, so a smaller value lets the window shrink
    /// below what `NavigationSplitView` + `.inspector` accept, and AppKit aborts in the window's
    /// update-constraints pass. Measured on macOS 27 (`BookEditorLayoutTests`): with the session
    /// panel shown the editor needs sidebar ideal + 2 × inspector ideal = 190 + 2 × 320 = 830 pt.
    static let minimumWidth: CGFloat = 840

    public var body: some View {
        Group {
            if let document {
                BookEditor(document: document)
            } else if let loadError {
                ContentUnavailableView("Couldn't Open the Book", systemImage: "exclamationmark.triangle",
                                       description: Text(loadError))
            } else if let lockOwner {
                ContentUnavailableView {
                    Label("Book in Use", systemImage: "lock")
                } description: {
                    Text(StoreErrorText.message(for: .locked(lockOwner)))
                } actions: {
                    Button("Open Read-Only") { Task { await load(readOnly: true) } }
                }
            } else {
                ProgressView("Opening…")
            }
        }
        .frame(minWidth: Self.minimumWidth, minHeight: 520)
        .task(id: bookID) { await load(readOnly: false) }
        .task { await app.reopenBooks { openWindow(value: $0) } }
        .alert(
            lockOwner.map { StoreErrorText.message(for: .locked($0)) } ?? "",
            isPresented: $showLockAlert
        ) {
            Button("Open Read-Only") { Task { await load(readOnly: true) } }
            Button("Close", role: .cancel) { dismiss() }
        } message: {
            Text("Another copy of BookBook is using it. You can open it read-only to look at it, but you won't be able to change it.")
        }
        .onChange(of: app.windowCloseRequests.contains(bookID)) { _, requested in
            guard requested else { return }
            app.windowDidClose(bookID)
            dismiss()
        }
        .onDisappear {
            let app = app, bookID = bookID
            Task { await app.closeBook(bookID) }
        }
    }

    private func load(readOnly: Bool) async {
        do {
            document = try await app.openBook(bookID, readOnly: readOnly)
            lockOwner = nil
        } catch StoreError.locked(let owner) {
            lockOwner = owner
            showLockAlert = true
        } catch {
            // A book that left the library while BookBook was closed (a window SwiftUI restored):
            // close quietly (A §6.1, PD §8.1).
            if case StoreError.notFound = error, !(await app.resolves(bookID)) {
                app.forgetBook(bookID)
                dismiss()
                return
            }
            loadError = StoreErrorText.message(for: error)
        }
    }
}

/// The open book: page list in the sidebar; the Pages overview or the page editor (canvas) in
/// the detail area, switched with the toolbar's Overview / Editor control (PD §7, §8.5); and
/// the session panel.
struct BookEditor: View {
    let document: BookDocument
    @Environment(\.undoManager) private var undoManager
    @Environment(AppModel.self) private var app
    @State private var pages: PagesController
    @State private var layouts: TemplateEditorModel
    @State private var styleModel: StyleTabModel
    @State private var sidebarTab: SidebarTab = .pages
    @State private var selectedImageBox: BoxID?
    @State private var showSession = true
    @State private var showTypography = false
    @State private var showNumbers = true
    @State private var images: ImageCache
    @State private var thumbnails: PageThumbnailRenderer

    init(document: BookDocument) {
        self.document = document
        let images = ImageCache(store: document.store)
        _images = State(initialValue: images)
        _thumbnails = State(initialValue: PageThumbnailRenderer(images: ImageCache(store: document.store,
                                                                                   maxPixelSize: 512)))
        _pages = State(initialValue: PagesController(document: document))
        _layouts = State(initialValue: TemplateEditorModel(document: document))
        _styleModel = State(initialValue: StyleTabModel(document: document))
    }

    var body: some View {
        @Bindable var pages = pages
        let content = document.content
        NavigationSplitView {
            sidebar(content)
                .safeAreaInset(edge: .top, spacing: 0) {
                    Picker("Sidebar", selection: $sidebarTab) {
                        ForEach(SidebarTab.allCases) { tab in Label(tab.title, systemImage: tab.symbol).help(tab.title).tag(tab) }
                    }
                    .pickerStyle(.segmented)
                    .labelStyle(.iconOnly)
                    .labelsHidden()
                    .padding(8)
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: 0) {
                        Divider()
                        BookSwitcher(document: document) { pages.sheet = .bookSettings }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                    }
                }
                .navigationSplitViewColumnWidth(min: 160, ideal: 190, max: 260)
        } detail: {
            detail(content)
        }
        .inspector(isPresented: $showSession) {
            sessionPanel(content)
                .inspectorColumnWidth(min: 260, ideal: 320, max: 460)
        }
        .toolbar { toolbar }
        .navigationTitle(content.book.title)
        .focusedSceneValue(\.focusedBook, document)
        .focusedSceneValue(\.showTypography, $showTypography)
        .focusedSceneValue(\.pagesController, pages)
        .sheet(isPresented: $showTypography) { TypographyForm(document: document) }
        .sheet(item: $pages.sheet, onDismiss: { pages.sheetDidDismiss() }) { sheet in
            sheetView(sheet, content: document.content)
        }
        .alert("This would split a spread across two sheets",
               isPresented: Binding(get: { pages.showsSplitWarning }, set: { _ in })) {
            // Every button resolves the warning; the binding's setter is a no-op so dismissal
            // can't race the chosen action.
            Button("Insert Blank Page") { pages.resolveSplit(.insertBlankPage) }
            Button(isReorder(pages.pendingSplit) ? "Move Anyway" : "Continue Anyway") {
                pages.resolveSplit(.moveAnyway)
            }
            Button("Cancel", role: .cancel) { pages.resolveSplit(.cancel) }
        } message: {
            Text("A two-page spread has to start on a left-hand page to print on one sheet. BookBook can insert a blank text page before it to keep it together.")
        }
        .onAppear {
            document.undoManager = undoManager
            if pages.selectedPage == nil { pages.selectedPage = content.book.pageOrder.first ?? content.book.coverPageID }
            // New Book from Story…: open straight into the import sheet.
            if document.isEditable, app.takePendingStoryImport(for: document.id) { pages.sheet = .importStory }
        }
        .onChange(of: undoManager) { _, manager in document.undoManager = manager }
        .onChange(of: content.book.pageOrder) {
            // An undo or redo can remove the selected page.
            pages.validateSelection()
        }
        .onChange(of: sidebarTab) { layouts.finishContinuousEdit() }
        .onChange(of: pages.selectedPage) { selectedImageBox = nil }
        .onChange(of: pages.mode) { _, mode in if mode == .overview { selectedImageBox = nil } }
    }

    @ViewBuilder
    private func sidebar(_ content: BookContent) -> some View {
        switch sidebarTab {
        case .pages, .style: PageList(document: document, content: content, pages: pages)
        case .layouts: TemplateList(document: document, content: content, model: layouts)
        }
    }

    private func isReorder(_ command: BookCommand?) -> Bool {
        if case .reorderPages = command { true } else { false }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        @Bindable var pages = pages
        ToolbarItem(placement: .navigation) {
            Picker("View", selection: $pages.mode) {
                Label("Overview", systemImage: "square.grid.2x2").tag(PagesController.Mode.overview)
                Label("Editor", systemImage: "doc.richtext").tag(PagesController.Mode.editor)
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            .help("Switch between the spread overview and the page editor")
        }
        ToolbarItemGroup {
            Button {
                pages.sheet = .addPage(index: pages.insertionIndex)
            } label: { Label("Add Page", systemImage: "plus.rectangle.on.rectangle") }
                .help("Add a page after the selected one")
                .disabled(!document.isEditable)
            Button { pages.sheet = .importStory } label: {
                Label("Import Story Text", systemImage: "text.badge.plus")
            }
            .help("Import story text and split it into pages")
            .disabled(!document.isEditable)
            Menu {
                Button("Book Settings…") { pages.sheet = .bookSettings }
                Button("Page Numbers…") { pages.sheet = .pageNumbers }
                Divider()
                Toggle("Show Page Numbers in Overview", isOn: $showNumbers)
            } label: {
                Label("Book", systemImage: "book.closed")
            }
            .help("Book settings, page numbers and typography")
            .disabled(!document.isEditable)
        }
        ToolbarItem {
            Button { showTypography = true } label: { Label("Typography", systemImage: "textformat") }
                .help("Fonts, size, colour and spacing for the whole book")
                .disabled(!document.isEditable)
        }
        ToolbarItem {
            Button { showSession.toggle() } label: { Label("Session", systemImage: "sidebar.trailing") }
                .help("Show or hide the session panel")
        }
    }

    @ViewBuilder
    private func sheetView(_ sheet: PagesController.Sheet, content: BookContent) -> some View {
        let presets = Presets.bundledTemplates
        let trim = content.style.pageSetup.trimSize
        switch sheet {
        case let .addPage(index):
            let choices = PagesOverviewModel.templateChoices(forCover: false, in: content, presets: presets)
            let current = pages.selectedPage.flatMap { content.pages[$0] }
                .flatMap { $0.kind == .story ? $0.templateID : nil }
            TemplatePickerSheet(title: "Add Page", confirmTitle: "Add", templates: choices, trimSize: trim,
                                initialSelection: current ?? Presets.storyTemplateID) { [pages] id in
                pages.dismissSheet { pages.addPage(templateID: id, at: index) }
            }
        case let .changeLayout(page):
            let choices = PagesOverviewModel.templateChoices(forCover: pages.isCover(page), in: content,
                                                             presets: presets)
            TemplatePickerSheet(title: pages.isCover(page) ? "Change Cover Layout" : "Change Layout",
                                confirmTitle: "Change", templates: choices, trimSize: trim,
                                initialSelection: content.pages[page]?.templateID) { [pages] id in
                pages.dismissSheet { pages.changeLayout(page, to: id) }
            }
        case .importStory:
            StoryImportSheet(document: document, pages: pages)
        case .bookSettings:
            BookSettingsSheet(document: document)
        case .pageNumbers:
            PageNumbersSheet(pages: pages, style: content.style.pageNumbers, content: content)
        }
    }

    @ViewBuilder
    private func detail(_ content: BookContent) -> some View {
        VStack(spacing: 0) {
            if document.isReadOnly {
                Label("Read-only: this book is open in BookBook somewhere else, so changes can't be made here.",
                      systemImage: "lock.fill")
                    .font(.callout)
                    .padding(8)
                    .frame(maxWidth: .infinity)
                    .background(.secondary.opacity(0.15))
            }
            if !document.missingFonts.isEmpty { MissingFontsBanner(fonts: document.missingFonts) }
            if sidebarTab == .pages && pages.mode == .editor {
                FormatBar(formatting: document.formatting)
                Divider()
            }
            if let error = document.lastSaveError {
                Label("Couldn't save changes: \(StoreErrorText.message(for: error))", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .padding(8)
                    .frame(maxWidth: .infinity)
                    .background(.yellow.opacity(0.25))
            }
            if sidebarTab == .layouts {
                LayoutsDetail(document: document, model: layouts, images: images)
            } else if sidebarTab == .style {
                StyleTab(document: document, model: styleModel)
            } else {
            switch pages.mode {
            case .overview:
                PagesOverview(document: document, pages: pages, thumbnails: thumbnails, showNumbers: $showNumbers)
            case .editor:
                if let page = pages.selectedPage, content.pages[page] != nil {
                    PageCanvas(document: document, content: content, pageID: page, imageSource: images,
                               selectedImageBox: $selectedImageBox) { [pages] in pages.sheet = .bookSettings }
                        // Read-only: no text editing or box selection (the canvas is AppKit).
                        .allowsHitTesting(document.isEditable)
                } else {
                    ContentUnavailableView("No Page Selected", systemImage: "doc",
                                           description: Text("Choose a page, or add one with +."))
                }
            }
            }
        }
    }

    @ViewBuilder
    private func sessionPanel(_ content: BookContent) -> some View {
        if sidebarTab == .layouts {
            BoxInspector(model: layouts)
                .disabled(!document.isEditable)
        } else if pages.mode == .editor, let page = pages.selectedPage, let box = selectedImageBox,
           content.pages[page]?.images[box] != nil {
            VStack(spacing: 0) {
                ImageFlagsRow(flags: content.imageFlags(page: page, box: box), editable: document.isEditable) {
                    styleModel.markOK(page: page, box: box)
                }
                SessionPanel(document: document, content: content, pageID: page, boxID: box, images: images)
                    .id(box)
            }
            .disabled(!document.isEditable)
        } else {
            ContentUnavailableView("No Image Box Selected", systemImage: "photo",
                                   description: Text(pages.mode == .editor
                                                     ? "Click an image box on the page to see its session."
                                                     : "Double-click a page to open it, then click an image box."))
        }
    }
}

/// The page list: the cover, then story pages in reading order. Click selects; double-click
/// opens the page editor; right-click for page commands; + inserts a page after the selection
/// and − deletes the selected story page (all undoable).
struct PageList: View {
    let document: BookDocument
    let content: BookContent
    let pages: PagesController

    var body: some View {
        @Bindable var pages = pages
        let cover = content.coverPage
        List(selection: $pages.selectedPage) {
            if let cover {
                row("Cover", status: content.status(of: cover), flags: content.imageFlags(of: cover)).tag(cover.id)
            }
            ForEach(PageListing.items(content)) { item in
                row(item.title, status: item.status, flags: item.flags).tag(item.id)
            }
        }
        .contextMenu(forSelectionType: PageID.self) { ids in
            if let page = ids.first {
                PageContextMenu(pages: pages, page: page,
                                flags: content.pages[page].map { content.imageFlags(of: $0) } ?? []) {
                    _ = document.perform(.markFlagsOK(page: page, box: nil))
                }
            }
        } primaryAction: { ids in
            if let page = ids.first { pages.open(page) }
        }
        .onDeleteCommand {
            if let page = pages.selectedPage { pages.delete(page) }
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 2) {
                Button { pages.sheet = .addPage(index: pages.insertionIndex) } label: { Image(systemName: "plus") }
                    .help("Add a page after the selected one")
                    .disabled(!document.isEditable)
                Button {
                    if let page = pages.selectedPage { pages.delete(page) }
                } label: { Image(systemName: "minus") }
                    .help("Delete the selected page")
                    .disabled(!document.isEditable || !pages.isStoryPage(pages.selectedPage))
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
    }

    private func row(_ title: String, status: PageStatus, flags: ImageFlags) -> some View {
        HStack {
            Text(title)
            Spacer()
            ImageFlagIcons(flags: flags).font(.caption)
            StatusBadge(status: status).font(.caption)
        }
    }
}
