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
    @State private var confirmTakeOver = false

    public init(bookID: BookID) {
        self.bookID = bookID
    }

    /// The window's minimum width: both panel cards at their minimums, the detail card's minimum
    /// and the desk gaps (`EditorPanelMetrics`: 160 + 260 + 320 + 4 × 10 = 780 pt), with room
    /// to spare. `BookEditorLayoutTests` checks the editor settles at this width.
    static let minimumWidth: CGFloat = 840

    public var body: some View {
        Group {
            if let document {
                BookEditor(document: document)
            } else if let loadError {
                CrayonEmptyState("Couldn't Open the Book", systemImage: "exclamationmark.triangle",
                                 color: Crayon.tomato, message: loadError) {
                    Button("Try Again") { Task { await retry() } }
                        .buttonStyle(.crayon)
                    closeButton
                }
            } else if let lockOwner {
                let offersOpenAnyway = LockTakeOver.offersOpenAnyway(lockOwner)
                CrayonEmptyState("Book in Use", systemImage: "lock", color: Crayon.grape,
                                 message: LockTakeOver.message(for: lockOwner, offersOpenAnyway: offersOpenAnyway)) {
                    Button("Open Read-Only") { Task { await load(readOnly: true) } }
                        .buttonStyle(.crayon)
                    if offersOpenAnyway {
                        Button("Open Anyway…") { confirmTakeOver = true }
                            .buttonStyle(.crayon(Crayon.sky))
                    }
                    closeButton
                }
            } else {
                VStack(spacing: 18) {
                    CrayonBlobIcon(systemImage: "book.fill", color: Crayon.sky, size: 64)
                    ProgressView("Opening…")
                        .font(Crayon.font(.headline, weight: .bold))
                        .foregroundStyle(Crayon.inkSoft)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: Self.minimumWidth, minHeight: 520)
        .task(id: bookID) { await load(readOnly: false) }
        .task { await app.reopenBooks { openWindow(value: $0) } }
        .alert("Open this book anyway?", isPresented: $confirmTakeOver) {
            Button("Open Anyway", role: .destructive) { Task { await openAnyway() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(LockTakeOver.warning)
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

    /// Closes the window (the book couldn't be opened, or the user won't open a locked one).
    private var closeButton: some View {
        Button("Close") { dismiss() }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
    }

    /// "Try Again" after a failed open: back to the opening state, then a fresh editable open.
    private func retry() async {
        loadError = nil
        lockOwner = nil
        await load(readOnly: false)
    }

    /// "Open Anyway" (#99b): takes the lock over from `lockOwner`, then opens the book editable.
    private func openAnyway() async {
        guard let owner = lockOwner, let url = app.entry(for: bookID)?.url else {
            await load(readOnly: false)
            return
        }
        let store = BookStore(packageURL: url)
        switch await LockTakeOver.takeOver(store, from: owner) {
        case .taken:
            // The store's hold is counted per process, so the real open finds the lock ours.
            await load(readOnly: false)
            await store.releaseLock()
        case let .changed(newOwner):
            // The lock changed hands while the warning was up: the locked screen now names the
            // new holder, so the user decides again.
            lockOwner = newOwner
        case let .failed(message):
            lockOwner = nil
            loadError = message
        }
    }

    private func load(readOnly: Bool) async {
        do {
            document = try await app.openBook(bookID, readOnly: readOnly)
            lockOwner = nil
        } catch StoreError.locked(let owner) {
            lockOwner = owner
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
    @State private var layoutChat: TemplateChatModel
    @State private var textStyles: TextStyleModel
    @State private var styleModel: StyleTabModel
    @State private var assetsModel = AssetsModel()
    @State private var styleSection: StyleSection = .visual
    @State private var styleScrollRequest = 0
    @State private var selectedBox: BoxID?
    @State private var canvasImportError: String?
    @State private var showTypography = false
    @State private var showExport = false
    /// The overview's Page Labels toggle, kept with the window across launches.
    @SceneStorage("pagesOverview.showsPageLabels") private var showPageLabels = true
    @State private var draftAllRequested = false
    @State private var images: ImageCache
    @State private var thumbnails: PageThumbnailRenderer

    init(document: BookDocument) {
        self.document = document
        let images = ImageCache(store: document.store)
        _images = State(initialValue: images)
        _thumbnails = State(initialValue: PageThumbnailRenderer(images: ImageCache(store: document.store,
                                                                                   maxPixelSize: 512)))
        _pages = State(initialValue: PagesController(document: document))
        let layouts = TemplateEditorModel(document: document)
        _layouts = State(initialValue: layouts)
        _layoutChat = State(initialValue: TemplateChatModel(document: document, editor: layouts))
        _textStyles = State(initialValue: TextStyleModel(document: document))
        _styleModel = State(initialValue: StyleTabModel(document: document))
    }

    /// The sidebar tab lives on `pages`, so opening a page or the overview from anywhere also
    /// brings the Pages tab forward.
    private var sidebarTab: SidebarTab { pages.sidebarTab }

    var body: some View {
        @Bindable var pages = pages
        let content = document.content
        EditorPanels(showsInspector: showsInspector) {
            sidebar(content)
                // Lists in every tab sit on the sidebar card.
                .scrollContentBackground(.hidden)
                .safeAreaInset(edge: .top, spacing: 0) {
                    VStack(spacing: 6) {
                        SidebarTabPicker(selection: $pages.sidebarTab)
                        // The Overview / Editor switch belongs to the Pages tab, so it sits on
                        // the sidebar card rather than in the title bar (which then looks the
                        // same on every tab).
                        if sidebarTab == .pages { PagesModePicker(selection: $pages.mode) }
                    }
                    .padding(8)
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: 6) {
                        if !app.isOnline { OfflineBadge() }
                        QueueBadge()
                        BookSwitcher(document: document) { pages.sheet = .bookSettings }
                    }
                    .padding(8)
                    .background(Crayon.paperDeep,
                                in: RoundedRectangle(cornerRadius: Crayon.mediumCornerRadius, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: Crayon.mediumCornerRadius, style: .continuous)
                            .strokeBorder(Crayon.ink.opacity(0.08), lineWidth: 1)
                    }
                    .padding(8)
                }
        } detail: {
            detail(content)
                .safeAreaInset(edge: .top, spacing: 0) {
                    if case .restored = app.queueSnapshot.pause { QueueResumeBanner(pause: app.queueSnapshot.pause) }
                }
        } inspector: {
            sessionPanel(content)
        }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .draftAllFlow(document: document, trigger: $draftAllRequested)
        .navigationTitle(content.book.title)
        .focusedSceneValue(\.focusedBook, document)
        .focusedSceneValue(\.showTypography, $showTypography)
        .focusedSceneValue(\.showExport, $showExport)
        .focusedSceneValue(\.pagesController, pages)
        .focusedSceneValue(\.draftAll, $draftAllRequested)
        .sheet(isPresented: $showTypography) { TypographyForm(document: document) }
        .sheet(isPresented: $showExport) {
            ExportSheet(model: ExportSheetModel(document: document, services: LiveExportServices(document: document)),
                        onOpenPage: { [pages] page in
                            showExport = false
                            pages.open(page)
                        },
                        onClose: { showExport = false })
        }
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
            // Taken even when read-only, so a stale flag can't fire later (#72b).
            if app.takePendingStoryImport(for: document.id), document.isEditable { pages.sheet = .importStory }
        }
        .onChange(of: undoManager) { _, manager in document.undoManager = manager }
        .onChange(of: content.book.pageOrder) {
            // An undo or redo can remove the selected page.
            pages.validateSelection()
        }
        .onChange(of: sidebarTab) { layouts.finishContinuousEdit() }
        .onChange(of: pages.selectedPage) { selectedBox = nil }
        .onChange(of: content.assets) { assetsModel.validate(document.content) }
        .onChange(of: pages.mode) { _, mode in if mode == .overview { selectedBox = nil } }
    }

    @ViewBuilder
    private func sidebar(_ content: BookContent) -> some View {
        switch sidebarTab {
        case .pages: PageList(document: document, content: content, pages: pages, thumbnails: thumbnails)
        case .style: StyleSectionList(selection: $styleSection, scrollRequest: $styleScrollRequest)
        case .assets: AssetsList(document: document, content: content, model: assetsModel, images: images)
        case .layouts: TemplateList(document: document, content: content, model: layouts, chat: layoutChat)
        }
    }

    /// Where-used link: the page editor on that page, with the box selected when there is one.
    private func openFromWhereUsed(_ page: PageID, _ box: BoxID?) {
        pages.open(page)  // switches to the Pages tab
        // `selectedPage` changing clears the box selection, so set it after that has run.
        Task { @MainActor in selectedBox = box }
    }

    private func isReorder(_ command: BookCommand?) -> Bool {
        if case .reorderPages = command { true } else { false }
    }

    /// The inspector card: the session panel on Pages and the chat / box inspector on Layouts,
    /// always shown there; none on Assets (the editor generates in place) or Style.
    private var showsInspector: Bool {
        switch sidebarTab {
        case .pages, .layouts: true
        case .assets, .style: false
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
                                initialSelection: content.pages[page]?.templateID,
                                currentTemplateID: content.pages[page]?.templateID) { [pages] id in
                pages.dismissSheet { pages.changeLayout(page, to: id) }
            }
        case .importStory:
            StoryImportSheet(document: document, pages: pages)
        case .bookSettings:
            BookSettingsSheet(document: document)
        case .importFromBook:
            ImportFromBookSheet(document: document)
        case .pageNumbers:
            PageNumbersSheet(pages: pages, style: content.style.pageNumbers, content: content)
        }
    }

    @ViewBuilder
    private func detail(_ content: BookContent) -> some View {
        VStack(spacing: 0) {
            if document.isReadOnly {
                CrayonBanner("Read-only: this book is open in BookBook somewhere else, so changes can't be made here.",
                             systemImage: "lock.fill", color: Crayon.grape)
            }
            if !document.missingFonts.isEmpty {
                MissingFontsBanner(fonts: document.missingFonts,
                                   onShowTypography: document.isEditable ? { showTypography = true } : nil)
            }
            if sidebarTab == .pages && pages.mode == .editor {
                FormatBar(formatting: document.formatting)
                Divider()
            }
            if let error = document.lastSaveError {
                CrayonBanner("Couldn't save changes. \(StoreErrorText.message(for: error))",
                             systemImage: "exclamationmark.triangle.fill", color: Crayon.sunflower,
                             glyphColor: Crayon.onSunflower) {
                    // The failed save stays pending in the store, so a flush writes it again.
                    Button("Try Again") { Task { await document.flush() } }
                        .buttonStyle(.crayon(Crayon.sunflower))
                }
            }
            if sidebarTab == .assets {
                AssetsDetail(document: document, content: content, model: assetsModel, images: images,
                             onOpenPage: openFromWhereUsed)
            } else if sidebarTab == .layouts {
                LayoutsDetail(document: document, model: layouts, images: images)
            } else if sidebarTab == .style {
                StyleTab(document: document, model: styleModel, section: styleSection, scrollRequest: styleScrollRequest,
                         onEditPageNumbers: { [pages] in pages.sheet = .pageNumbers })
            } else {
            switch pages.mode {
            case .overview:
                PagesOverview(document: document, pages: pages, thumbnails: thumbnails, showLabels: $showPageLabels)
            case .editor:
                if let page = pages.selectedPage, content.pages[page] != nil {
                    PageCanvas(document: document, content: content, pageID: page, imageSource: images,
                               selectedImageBox: $selectedBox,
                               onOpenBookSettings: { [pages] in pages.sheet = .bookSettings },
                               onDropImageFiles: { page, box, urls in importDroppedImages(urls, page: page, box: box) })
                        // Read-only: no text editing or box selection (the canvas is AppKit).
                        .allowsHitTesting(document.isEditable)
                        .alert("Couldn't use that image", isPresented: $canvasImportError.isPresent()) {
                            Button("OK", role: .cancel) {}
                        } message: { Text(canvasImportError ?? "") }
                } else {
                    CrayonEmptyState("No Page Selected", systemImage: "doc", color: Crayon.sky,
                                     message: "Choose a page, or add one with +.")
                }
            }
            }
        }
    }

    /// "Use your own image" by dropping files on an image box (PD §8.6): selects the box and
    /// imports each file as a version (the first auto-places if the box is empty).
    private func importDroppedImages(_ urls: [URL], page: PageID, box: BoxID) {
        selectedBox = box
        let document = document
        Task {
            for url in urls {
                do {
                    _ = try await document.importImage(from: url, page: page, box: box)
                } catch {
                    canvasImportError = ImageImportFailure.message(for: error)
                }
            }
        }
    }

    @ViewBuilder
    private func sessionPanel(_ content: BookContent) -> some View {
        if sidebarTab == .layouts {
            LayoutsInspector(document: document, editor: layouts, chat: layoutChat)
        } else if pages.mode == .editor, let page = pages.selectedPage, let box = selectedBox,
           content.pages[page]?.images[box] != nil {
            VStack(spacing: 0) {
                ImageFlagsRow(flags: content.imageFlags(page: page, box: box), editable: document.isEditable) {
                    styleModel.markOK(page: page, box: box)
                }
                SessionPanel(document: document, content: content, pageID: page, boxID: box)
                    .id(box)
            }
            .disabled(!document.isEditable)
        } else if pages.mode == .editor, let page = pages.selectedPage, let box = selectedBox,
                  let template = content.pages[page].flatMap(content.template(for:)),
                  case .text = template.box(box)?.content {
            TextStylePanel(document: document, content: content, model: textStyles, pageID: page, boxID: box)
                .id(box)
                .disabled(!document.isEditable)
        } else {
            CrayonEmptyState("Nothing Selected", systemImage: "cursorarrow.click.2", color: Crayon.bubblegum,
                             message: pages.mode == .editor
                                 ? "Click an image box to see its session, or a text box to style it with AI."
                                 : "Double-click a page to open it, then click a box.")
        }
    }
}

/// The page list: the cover, then story pages in reading order. Click selects; double-click
/// opens the page editor; right-click for page commands (including delete); the + row under the
/// last page inserts a page after the selection (all undoable).
struct PageList: View {
    let document: BookDocument
    let content: BookContent
    let pages: PagesController
    let thumbnails: PageThumbnailRenderer
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        @Bindable var pages = pages
        let cover = content.coverPage
        List(selection: $pages.selectedPage) {
            if let cover {
                row("Cover", page: cover.id, status: content.status(of: cover), flags: content.imageFlags(of: cover),
                    selected: pages.selectedPage == cover.id).tag(cover.id)
            }
            ForEach(PageListing.items(content)) { item in
                row(item.title, page: item.id, status: item.status, flags: item.flags,
                    selected: pages.selectedPage == item.id).tag(item.id)
            }
            Button { pages.sheet = .addPage(index: pages.insertionIndex) } label: {
                Image(systemName: "plus")
                    .font(Crayon.font(.body, weight: .bold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Add a page after the selected one")
            .accessibilityLabel("Add Page")
            .disabled(!document.isEditable)
            .selectionDisabled()
            .listRowSeparator(.hidden)
        }
        .contextMenu(forSelectionType: PageID.self) { ids in
            if let page = ids.first {
                PageContextMenu(pages: pages, page: page)
            }
        } primaryAction: { ids in
            if let page = ids.first { pages.open(page) }
        }
        .onDeleteCommand {
            if let page = pages.selectedPage { pages.delete(page) }
        }
    }

    /// A page row as a white mini card on the sidebar card: a thumbnail of the page, its title
    /// and layout name. The selected one is filled tomato and lifts on a deeper shadow.
    private func row(_ title: String, page: PageID, status: PageStatus, flags: ImageFlags,
                     selected: Bool) -> some View {
        let tile = RoundedRectangle(cornerRadius: Crayon.smallCornerRadius, style: .continuous)
        let layoutName = content.pages[page].flatMap { content.templates[$0.templateID]?.name }
        return HStack(spacing: 8) {
            thumbnail(page, selected: selected)
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(Crayon.font(.body, weight: .bold))
                    .foregroundStyle(selected ? Color.white : Crayon.ink)
                if let layoutName {
                    Text(layoutName)
                        .font(Crayon.font(.caption, weight: .semibold))
                        .foregroundStyle(selected ? Color.white.opacity(0.85) : Crayon.inkSoft)
                }
            }
            .lineLimit(1)
            Spacer(minLength: 0)
            ImageFlagIcons(flags: flags).font(.caption)
            StatusBadge(status: status, compact: true)
        }
        .padding(.vertical, 2)
        .listRowSeparator(.hidden)
        .listRowBackground(
            tile.fill(selected ? Crayon.tomato : Crayon.card)
                .overlay { tile.strokeBorder(Crayon.ink.opacity(selected ? 0 : 0.08), lineWidth: 1) }
                .background { tile.fill(Crayon.shadow).offset(y: selected ? 3 : 2) }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
        )
    }

    /// The page's art, 30 pt high (a spread comes out wider), on a paper well until it renders.
    private func thumbnail(_ page: PageID, selected: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: Crayon.thumbCornerRadius, style: .continuous)
        let image = thumbnails.image(for: page, in: content, marks: [],
                                     pixelHeight: Int(30 * max(1, displayScale)),
                                     fontsRevision: document.fontsRevision)
        return Group {
            if let image {
                Image(decorative: image, scale: max(1, displayScale))
                    .resizable()
                    .frame(width: min(52, 30 * Double(image.width) / Double(max(1, image.height))), height: 30)
                    .clipShape(shape)
                    .overlay {
                        shape.strokeBorder(selected ? Color.white : Crayon.ink.opacity(0.15),
                                           lineWidth: selected ? 2 : 1)
                    }
            } else {
                shape.fill(Crayon.paperDeep).frame(width: 24)
            }
        }
        .frame(height: 30)
    }
}

/// The sidebar's tab switcher: a chunky card of icon buttons, the chosen tab filled with its own
/// crayon colour. Stands in for the segmented "Sidebar" picker, with the same labels and help.
private struct SidebarTabPicker: View {
    @Binding var selection: SidebarTab
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let tile = RoundedRectangle(cornerRadius: Crayon.thumbCornerRadius, style: .continuous)
        HStack(spacing: 3) {
            ForEach(SidebarTab.allCases) { tab in
                let selected = selection == tab
                Button { selection = tab } label: {
                    Image(systemName: tab.symbol)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(selected ? Color.white : tab.crayonColor)
                        .frame(maxWidth: .infinity, minHeight: 26)
                        .background {
                            if selected {
                                tile.fill(tab.crayonColor)
                                    .shadow(color: Crayon.shadow, radius: 0, x: 0, y: 2)
                            }
                        }
                        .contentShape(tile)
                }
                .buttonStyle(.plain)
                .help(tab.title)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(4)
        .background {
            RoundedRectangle(cornerRadius: Crayon.mediumCornerRadius, style: .continuous)
                .fill(Crayon.card)
                .shadow(color: Crayon.shadow, radius: 0, x: 0, y: 2)
        }
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.7), value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sidebar")
    }
}

/// The Pages tab's Overview / Editor switch: two labelled segments on a card, styled like the
/// tab picker above it.
private struct PagesModePicker: View {
    @Binding var selection: PagesController.Mode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let tile = RoundedRectangle(cornerRadius: Crayon.thumbCornerRadius, style: .continuous)
        HStack(spacing: 3) {
            segment("Overview", systemImage: "square.grid.2x2", mode: .overview, tile: tile)
            segment("Editor", systemImage: "doc.richtext", mode: .editor, tile: tile)
        }
        .padding(3)
        .background {
            RoundedRectangle(cornerRadius: Crayon.smallCornerRadius, style: .continuous)
                .fill(Crayon.card)
                .shadow(color: Crayon.shadow, radius: 0, x: 0, y: 2)
        }
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.7), value: selection)
        .help("Switch between the spread overview and the page editor")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("View")
    }

    private func segment(_ title: String, systemImage: String, mode: PagesController.Mode,
                         tile: RoundedRectangle) -> some View {
        let selected = selection == mode
        return Button { selection = mode } label: {
            Label(title, systemImage: systemImage)
                .font(Crayon.font(.caption, weight: .bold))
                .foregroundStyle(selected ? Color.white : Crayon.ink)
                .frame(maxWidth: .infinity, minHeight: 22)
                .background { if selected { tile.fill(Crayon.tomato) } }
                .contentShape(tile)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Shown at the foot of the sidebar while the network is down (it used to be a toolbar item,
/// which changed the title bar's height).
private struct OfflineBadge: View {
    var body: some View {
        Label("Offline", systemImage: "wifi.slash")
            .font(Crayon.font(.caption, weight: .bold))
            .foregroundStyle(Crayon.inkSoft)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .crayonCard(cornerRadius: Crayon.mediumCornerRadius)
            .help("Offline: queued requests will run when the network returns")
    }
}

private extension SidebarTab {
    var crayonColor: Color {
        switch self {
        case .pages: Crayon.tomato
        case .assets: Crayon.grape
        case .layouts: Crayon.sky
        case .style: Crayon.grass
        }
    }
}

/// "Open Anyway" for a book whose lock another process holds (#99b). Offered for locks from
/// another Mac (which can't be proved stale from here); a live lock on this Mac keeps the
/// read-only choice only.
enum LockTakeOver {
    enum Outcome: Equatable {
        case taken
        case changed(LockOwner)
        case failed(String)
    }

    static let warning = "If another Mac is still editing this book, its changes and yours can overwrite each other and work can be lost. Only continue if you know the other copy of BookBook is closed, for example after a crash."

    /// The locked screen's message: who holds the book (named once), then what can be done.
    static func message(for owner: LockOwner, offersOpenAnyway: Bool) -> String {
        let advice = offersOpenAnyway
            ? "You can open it read-only to look at it. If BookBook on that Mac has quit or crashed, you can open it anyway."
            : "You can open it read-only to look at it, but you won't be able to change it."
        return "\(StoreErrorText.message(for: .locked(owner))) \(advice)"
    }

    /// Whether the locked screen offers "Open Anyway": the lock names a different Mac than
    /// `thisMachine` (by host UUID when both sides have one, else by host name). Tests pass a
    /// stand-in for this Mac.
    static func offersOpenAnyway(_ owner: LockOwner?, thisMachine: LockOwner = .current) -> Bool {
        guard let owner else { return false }
        return !owner.isOnSameMachine(as: thisMachine)
    }

    /// Takes `.lock` over from `owner` with `store`; the caller releases the store's hold once
    /// the book has opened.
    static func takeOver(_ store: BookStore, from owner: LockOwner) async -> Outcome {
        do {
            switch try await store.takeOverLock(expectedOwner: owner) {
            case .acquired: return .taken
            case let .heldByOther(newOwner): return .changed(newOwner)
            }
        } catch {
            return .failed(StoreErrorText.message(for: error))
        }
    }
}
