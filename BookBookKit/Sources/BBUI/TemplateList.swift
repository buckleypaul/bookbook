import BBModel
import BBStore
import SwiftUI

/// The sidebar's tabs. Style and Assets join in Phases 7 and 10.
enum SidebarTab: String, CaseIterable, Identifiable {
    case pages, layouts
    var id: String { rawValue }
    var title: String { switch self { case .pages: "Pages"; case .layouts: "Layouts" } }
    var symbol: String { switch self { case .pages: "doc.on.doc"; case .layouts: "rectangle.3.group" } }
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

/// The Layouts tab's sidebar: templates grouped by kind, with New Layout, New Spread, Duplicate,
/// Delete (blocked while in use) and Rename.
struct TemplateList: View {
    let document: BookDocument
    let content: BookContent
    let model: TemplateEditorModel
    @State private var renaming: TemplateID?
    @State private var renameText = ""
    @State private var confirmDelete: TemplateID?
    @FocusState private var renameFocused: Bool

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
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
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
                    .foregroundStyle(inBook ? .primary : .secondary)
                    .onTapGesture(count: 2) { beginRename(template) }
            }
            Spacer(minLength: 0)
            if inBook {
                let n = content.pages(using: template.id).count
                if n > 0 { Text("\(n)").font(.caption).foregroundStyle(.secondary).help("Used on \(n) page(s)") }
            }
        }
    }

    @ViewBuilder
    private func menu(_ id: TemplateID) -> some View {
        Button("Rename") { if let t = content.templates[id] ?? Presets.bundledTemplates.first(where: { $0.id == id }) { beginRename(t) } }
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
        guard !name.isEmpty, name != (content.templates[id]?.name ?? Presets.bundledTemplates.first { $0.id == id }?.name)
        else { return }
        if model.templateID != id { model.open(id) }  // a preset copies in with this edit's undo step
        model.update(actionName: "Rename Layout") { $0.name = name }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            if let id = model.templateID, content.templates[id] != nil {
                let used = LayoutsListing.usage(of: id, in: content)
                if !used.isEmpty {
                    Text("Used on: \(used.joined(separator: ", ")). Change those pages' layout before deleting.")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                }
            }
            HStack(spacing: 4) {
                Button { model.newTemplate(kind: .single) } label: { Label("New Layout", systemImage: "plus") }
                    .help("Add a blank single-page layout")
                Button { model.newTemplate(kind: .spread) } label: { Label("New Spread", systemImage: "plus.rectangle") }
                    .help("Add a blank two-page spread layout")
                Button { if let id = model.templateID { model.duplicate(id) } } label: {
                    Label("Duplicate", systemImage: "plus.square.on.square")
                }
                .help("Duplicate the selected layout")
                .disabled(model.templateID == nil)
                Button { if let id = model.templateID { requestDelete(id) } } label: {
                    Label("Delete", systemImage: "minus")
                }
                .help(deleteHelp)
                .disabled(model.templateID.map { !canDelete($0) } ?? true)
                Spacer(minLength: 0)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .disabled(!document.isEditable)
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .background(.bar)
    }

    private var deleteHelp: String {
        guard let id = model.templateID, content.templates[id] != nil else { return "Delete the selected layout" }
        return content.pages(using: id).isEmpty ? "Delete the selected layout"
            : "In use: change those pages to another layout first"
    }
}
