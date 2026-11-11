import BBModel
import BBStore
import SwiftUI

/// The sidebar's tabs.
enum SidebarTab: String, CaseIterable, Identifiable {
    case pages, assets, layouts, style
    var id: String { rawValue }
    var title: String { switch self { case .pages: "Pages"; case .assets: "Assets"; case .layouts: "Layouts"; case .style: "Style" } }
    var symbol: String {
        switch self { case .pages: "doc.on.doc"; case .assets: "person.2"; case .layouts: "rectangle.3.group"; case .style: "paintpalette" }
    }
}

/// Pure helpers behind the Layouts list.
enum LayoutsListing {
    struct Section: Identifiable {
        var kind: TemplateKind
        var templates: [Template]
        var id: TemplateKind { kind }
        var title: String { switch kind { case .single: "Single"; case .spread: "Spread"; case .cover: "Cover" } }
    }

    /// Book templates plus bundled presets the book hasn't copied yet, grouped Single / Spread /
    /// Cover (empty groups left out). The book's copy wins over its preset.
    static func sections(in content: BookContent, presets: [Template]) -> [Section] {
        let all = PagesOverviewModel.templateChoices(forCover: false, in: content, presets: presets)
            + PagesOverviewModel.templateChoices(forCover: true, in: content, presets: presets)
        return [TemplateKind.single, .spread, .cover].compactMap { kind in
            let items = all.filter { $0.kind == kind }
            return items.isEmpty ? nil : Section(kind: kind, templates: items)
        }
    }

    /// Where a template is used: "Cover", then "Page N" in reading order.
    static func usage(of id: TemplateID, in content: BookContent) -> [String] {
        let numbers = Dictionary(uniqueKeysWithValues: PageListing.items(content).map { ($0.id, $0.title) })
        return content.pages(using: id).map { $0 == content.book.coverPageID ? "Cover" : (numbers[$0] ?? "Page") }
    }
}

/// The Layouts tab's sidebar: templates grouped by kind, with a New menu (Layout, Spread, AI) and
/// an actions menu for the selection (Rename, Duplicate, Delete — blocked while in use).
struct TemplateList: View {
    let document: BookDocument
    let content: BookContent
    let model: TemplateEditorModel
    @State private var renaming: TemplateID?
    @State private var renameText = ""
    @State private var confirmDelete: TemplateID?
    @FocusState private var renameFocused: Bool
    @Environment(AppModel.self) private var app
    @State private var showAISheet = false

    var body: some View {
        let sections = LayoutsListing.sections(in: content, presets: Presets.bundledTemplates)
        List(selection: Binding(get: { model.templateID }, set: { if let id = $0 { model.open(id) } })) {
            ForEach(sections) { section in
                Section(section.title) {
                    ForEach(section.templates) { template in
                        row(template).tag(template.id)
                    }
                }
            }
        }
        .contextMenu(forSelectionType: TemplateID.self) { ids in
            if let id = ids.first { menu(id) }
        }
        .onDeleteCommand { if let id = model.templateID { requestDelete(id) } }
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .sheet(isPresented: $showAISheet) {
            TemplateGenerationSheet(app: app, document: document, editor: model)
        }
        .confirmationDialog("Delete this layout?", isPresented: Binding(get: { confirmDelete != nil },
                                                                         set: { if !$0 { confirmDelete = nil } }),
                            presenting: confirmDelete) { id in
            Button("Delete", role: .destructive) { model.delete(id) }
        } message: { id in
            Text("“\(content.templates[id]?.name ?? "")” will be removed from the book. You can undo this.")
        }
    }

    private func row(_ template: Template) -> some View {
        let inBook = content.templates[template.id] != nil
        let aspect = content.style.pageSetup.trimSize.width / max(1, content.style.pageSetup.trimSize.height)
        let height: CGFloat = 32
        return HStack(spacing: 8) {
            TemplateDiagram(template: template)
                .frame(width: height * aspect * (template.kind == .spread ? 2 : 1), height: height)
            if renaming == template.id {
                TextField("Name", text: $renameText)
                    .focused($renameFocused)
                    .onSubmit { commitRename(template.id) }
                    .onChange(of: renameFocused) { _, focused in if !focused { commitRename(template.id) } }
                    .onExitCommand { renaming = nil }
            } else {
                Text(template.name).lineLimit(2)
                    .font(Crayon.font(.body, weight: inBook ? .semibold : .regular))
                    .foregroundStyle(inBook ? Crayon.ink : Crayon.inkSoft)
                    .onTapGesture(count: 2) { beginRename(template) }
            }
            Spacer(minLength: 0)
            if inBook {
                let n = content.pages(using: template.id).count
                if n > 0 { CrayonSticker("\(n)", color: Crayon.sky).help("Used on \(n) page(s)") }
            }
        }
    }

    @ViewBuilder
    private func menu(_ id: TemplateID) -> some View {
        Button("Rename") { if let t = Presets.template(id, in: content) { beginRename(t) } }
        Button("Duplicate") { model.duplicate(id) }
        Divider()
        Button("Delete…", role: .destructive) { requestDelete(id) }
            .disabled(!canDelete(id))
    }

    private func canDelete(_ id: TemplateID) -> Bool {
        document.isEditable && content.templates[id] != nil && content.pages(using: id).isEmpty
    }

    private func requestDelete(_ id: TemplateID) {
        if canDelete(id) { confirmDelete = id }
    }

    private func beginRename(_ template: Template) {
        guard document.isEditable else { return }
        renameText = template.name
        renaming = template.id
        renameFocused = true
    }

    private func commitRename(_ id: TemplateID) {
        guard renaming == id else { return }
        renaming = nil
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != Presets.template(id, in: content)?.name
        else { return }
        if model.templateID != id { model.open(id) }  // a preset copies in with this edit's undo step
        model.update(actionName: "Rename Layout") { $0.name = name }
    }

    /// New (with its kinds spelled out) and the selected layout's actions, above the list so
    /// they're easy to find. Every action is a labelled menu item rather than a bare icon.
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Menu {
                    Button("New Layout", systemImage: "rectangle.portrait") { model.newTemplate(kind: .single) }
                    Button("New Spread", systemImage: "rectangle.split.2x1") { model.newTemplate(kind: .spread) }
                    Divider()
                    Button("New with AI…", systemImage: "sparkles") { showAISheet = true }
                } label: {
                    Label("New", systemImage: "plus")
                        .labelStyle(.titleAndIcon)
                        .font(Crayon.font(.body, weight: .bold))
                        .foregroundStyle(Crayon.tomato)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Add a blank page or spread layout, or describe one for AI to draw")
                Spacer(minLength: 0)
                Menu {
                    if let id = model.templateID { menu(id) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .fontWeight(.bold)
                        .foregroundStyle(Crayon.tomato)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Rename, duplicate or delete the selected layout")
                .disabled(model.templateID == nil)
            }
            .disabled(!document.isEditable)
            if let id = model.templateID, content.templates[id] != nil {
                let used = LayoutsListing.usage(of: id, in: content)
                if !used.isEmpty {
                    Text("Used on: \(used.joined(separator: ", ")). Change those pages' layout before deleting.")
                        .font(Crayon.font(.caption, weight: .medium)).foregroundStyle(Crayon.inkSoft)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }
}
