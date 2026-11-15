import BBModel
import BBStore
import SwiftUI

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
