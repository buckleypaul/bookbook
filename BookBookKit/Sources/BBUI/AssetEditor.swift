import BBModel
import SwiftUI

/// Pure asset edits and labels (no views), so they're testable.
enum AssetEditing {
    static func typeTitle(_ type: AssetType) -> String {
        switch type { case .character: "Character"; case .place: "Place / Scene"; case .object: "Object" }
    }

    static func typeSymbol(_ type: AssetType) -> String {
        switch type { case .character: "person"; case .place: "mountain.2"; case .object: "cube" }
    }

    static func title(of kind: SheetItemKind) -> String {
        switch kind {
        case let .view(view):
            switch view {
            case .front: "Front view"
            case .threeQuarter: "Three-quarter view"
            case .side: "Side view"
            case .back: "Back view"
            }
        case let .expression(name):
            name.prefix(1).uppercased() + name.dropFirst()
        }
    }

    /// Assets of `type` (all when nil), by name.
    static func list(_ content: BookContent, type: AssetType?) -> [Asset] {
        content.assets.values.filter { type == nil || $0.type == type }
            .sorted {
                let order = $0.name.localizedCaseInsensitiveCompare($1.name)
                return order == .orderedSame ? $0.id.rawValue.uuidString < $1.id.rawValue.uuidString
                    : order == .orderedAscending
            }
    }

    static func chosenImage(sessionID: SessionID, chosen: VersionID?, in content: BookContent) -> ImageRef? {
        guard let chosen else { return nil }
        return content.sessions[sessionID]?.version(chosen)?.image
    }

    static func thumbnail(of asset: Asset, in content: BookContent) -> ImageRef? {
        guard let slot = asset.primary else { return nil }
        return chosenImage(sessionID: slot.sessionID, chosen: slot.chosen, in: content)
    }

    // MARK: Tags

    static func tagsText(_ tags: [String]) -> String { tags.joined(separator: ", ") }

    static func parseTags(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    // MARK: Slots

    static func addSlot(to asset: inout Asset) {
        asset.references.append(ReferenceSlot(label: "Reference \(asset.references.count + 1)", isPrimary: false))
    }

    /// Not the primary, and never the last slot.
    static func canRemoveSlot(_ id: UUID, from asset: Asset) -> Bool {
        asset.references.count > 1 && asset.references.contains { $0.id == id && !$0.isPrimary }
    }

    static func removeSlot(_ id: UUID, from asset: inout Asset) {
        guard canRemoveSlot(id, from: asset) else { return }
        asset.references.removeAll { $0.id == id }
    }

    static func renameSlot(_ id: UUID, to label: String, in asset: inout Asset) {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = asset.references.firstIndex(where: { $0.id == id }) else { return }
        asset.references[i].label = trimmed
    }

    static func makePrimary(_ id: UUID, in asset: inout Asset) {
        guard asset.references.contains(where: { $0.id == id }) else { return }
        for i in asset.references.indices { asset.references[i].isPrimary = asset.references[i].id == id }
    }

    // MARK: Sheet

    /// Ignores empty names and names already on the sheet (case-insensitive).
    static func addExpression(_ name: String, to asset: inout Asset) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty, var sheet = asset.sheet else { return }
        let exists = sheet.items.contains {
            if case let .expression(n) = $0.kind { n.lowercased() == trimmed } else { false }
        }
        guard !exists else { return }
        sheet.items.append(SheetItem(kind: .expression(trimmed)))
        asset.sheet = sheet
    }

    static func removeSheetItem(_ id: UUID, from asset: inout Asset) {
        asset.sheet?.items.removeAll { $0.id == id }
    }

    static func setLocked(_ locked: Bool, item id: UUID, in asset: inout Asset) {
        guard let i = asset.sheet?.items.firstIndex(where: { $0.id == id }) else { return }
        asset.sheet?.items[i].locked = locked
    }

    // MARK: Delete

    static func deleteMessage(name: String, sites: [UsageSite], in content: BookContent) -> String {
        WhereUsedText.summary(sites, in: content)
            + " Its pictures are kept in the book. Mentions of \(name) in prompts become plain text, and it is removed from page asset lists."
            + " This can't be undone."
    }
}

/// A text field that commits on Return, on losing focus, or when it disappears: one undo step.
struct CommittedTextField: View {
    let title: String
    let value: String
    var multiline = false
    let commit: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if multiline {
                TextEditor(text: $draft)
                    .font(.body)
                    .frame(minHeight: 70)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
            } else {
                TextField(title, text: $draft).onSubmit(flush)
            }
        }
        .focused($focused)
        .onAppear { draft = value }
        .onChange(of: value) { _, new in if !focused { draft = new } }
        .onChange(of: focused) { _, now in if !now { flush() } }
        .onDisappear(perform: flush)
        .accessibilityLabel(title)
    }

    private func flush() {
        if draft != value { commit(draft) }
    }
}

/// The asset editor (PD §8.3): name, description, tags, reference slots, sheet, where used, delete.
struct AssetEditor: View {
    let document: BookDocument
    let content: BookContent
    let asset: Asset
    let images: ImageCache
    let model: AssetsModel
    let onOpenPage: (PageID, BoxID?) -> Void
    let onGenerateSheet: () -> Void
    @State private var confirmDelete = false

    private var editable: Bool { document.isEditable }

    var body: some View {
        let sites = document.usageSites(of: asset.id)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                field("Description") {
                    CommittedTextField(title: "Description", value: asset.description, multiline: true) { text in
                        model.update(asset, in: document, actionName: "Edit Description") { $0.description = text }
                    }
                }
                field("Tags") {
                    CommittedTextField(title: "Tags, separated by commas", value: AssetEditing.tagsText(asset.tags)) { text in
                        model.update(asset, in: document, actionName: "Edit Tags") { $0.tags = AssetEditing.parseTags(text) }
                    }
                }
                slots
                if asset.type == .character {
                    Divider()
                    CharacterSheetView(document: document, content: content, asset: asset, images: images,
                                       model: model, onGenerate: onGenerateSheet)
                }
                Divider()
                Text("Where Used").font(.headline)
                WhereUsedList(sites: sites, content: content, onOpen: onOpenPage)
                Divider()
                Button("Delete Asset…", role: .destructive) { confirmDelete = true }
                    .disabled(!editable)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .disabled(!editable)
        .alert("Delete \(asset.name)?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                if document.deleteAsset(asset.id) { model.didDelete(asset.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(AssetEditing.deleteMessage(name: asset.name, sites: sites, in: content))
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: AssetEditing.typeSymbol(asset.type)).foregroundStyle(.secondary)
            CommittedTextField(title: "Name", value: asset.name) { text in
                let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                model.update(asset, in: document, actionName: "Rename Asset") { $0.name = name }
            }
            .font(.title2)
            Text(AssetEditing.typeTitle(asset.type)).foregroundStyle(.secondary)
        }
    }

    private func field(_ title: String, @ViewBuilder _ body: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            body()
        }
    }

    private var slots: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Reference Images").font(.headline)
                Spacer()
                Button("Add Reference") {
                    model.update(asset, in: document, actionName: "Add Reference") { AssetEditing.addSlot(to: &$0) }
                }
            }
            ForEach(asset.references) { slot in
                let owner = SessionOwner.assetReference(asset.id, slot.id)
                HStack {
                    Button {
                        model.update(asset, in: document, actionName: "Change Primary Reference") {
                            AssetEditing.makePrimary(slot.id, in: &$0)
                        }
                    } label: { Image(systemName: slot.isPrimary ? "largecircle.fill.circle" : "circle") }
                        .buttonStyle(.borderless)
                        .help("Primary reference")
                        .accessibilityLabel(slot.isPrimary ? "Primary reference" : "Make primary")
                    AssetThumbnail(ref: AssetEditing.chosenImage(sessionID: slot.sessionID, chosen: slot.chosen,
                                                                 in: content), images: images)
                    CommittedTextField(title: "Reference name", value: slot.label) { text in
                        model.update(asset, in: document, actionName: "Rename Reference") {
                            AssetEditing.renameSlot(slot.id, to: text, in: &$0)
                        }
                    }
                    Button { model.update(asset, in: document, actionName: "Remove Reference") {
                        AssetEditing.removeSlot(slot.id, from: &$0) } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .help("Remove reference")
                        .disabled(!AssetEditing.canRemoveSlot(slot.id, from: asset))
                    Button("Open") { model.selectedOwner = owner }
                }
                .padding(6)
                .background(model.selectedOwner == owner ? Color.accentColor.opacity(0.18) : .clear,
                            in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
                .onTapGesture { model.selectedOwner = owner }
            }
        }
    }
}
