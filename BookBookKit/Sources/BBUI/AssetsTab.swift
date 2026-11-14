import BBModel
import SwiftUI

/// Selection and edit plumbing for the Assets tab.
@MainActor @Observable
final class AssetsModel {
    var selectedAsset: AssetID?
    var typeFilter: AssetType?

    /// Applies `edit` to `asset` and performs one `updateAsset` command (skipped when nothing changed).
    func update(_ asset: Asset, in document: BookDocument, actionName: String, _ edit: (inout Asset) -> Void) {
        guard document.isEditable else { return }
        // Edit the live value so a stale view copy can't overwrite newer changes.
        var updated = document.content.assets[asset.id] ?? asset
        let before = updated
        edit(&updated)
        guard updated != before else { return }
        _ = document.perform(.updateAsset(updated, actionName: actionName))
    }

    func create(_ type: AssetType, name: String, in document: BookDocument) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard document.isEditable, !trimmed.isEmpty else { return }
        let asset = Asset.makeNew(type: type, name: trimmed)
        guard document.perform(.addAsset(asset)) else { return }
        select(asset)
    }

    func select(_ asset: Asset) {
        selectedAsset = asset.id
    }

    func didDelete(_ id: AssetID) {
        if selectedAsset == id { selectedAsset = nil }
    }

    /// An undo can remove the selected asset.
    func validate(_ content: BookContent) {
        guard let id = selectedAsset else { return }
        if content.assets[id] == nil { selectedAsset = nil }
    }
}

/// The Assets tab's sidebar: assets filtered by type, with a + menu to create each type.
struct AssetsList: View {
    let document: BookDocument
    let content: BookContent
    let model: AssetsModel
    let images: ImageCache
    @State private var newType: AssetType?
    @State private var newName = ""

    var body: some View {
        @Bindable var model = model
        let assets = AssetEditing.list(content, type: model.typeFilter)
        VStack(spacing: 0) {
            HStack {
                Picker("Type", selection: $model.typeFilter) {
                    Text("All").tag(AssetType?.none)
                    ForEach(AssetType.allCases, id: \.self) { Text(AssetEditing.typeTitle($0)).tag(AssetType?.some($0)) }
                }
                .labelsHidden()
                Menu {
                    ForEach(AssetType.allCases, id: \.self) { type in
                        Button("New \(AssetEditing.typeTitle(type))…", systemImage: AssetEditing.typeSymbol(type)) {
                            newName = ""
                            newType = type
                        }
                    }
                } label: {
                    Image(systemName: "plus")
                        .fontWeight(.heavy)
                        .foregroundStyle(Crayon.tomato)
                }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("New asset")
                    .accessibilityLabel("New asset")
                    .disabled(!document.isEditable)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 6)
            List(selection: Binding(get: { model.selectedAsset },
                                    set: { id in if let id, let a = content.assets[id] { model.select(a) } })) {
                ForEach(assets) { asset in
                    let color = Crayon.color(forKey: asset.id.rawValue.uuidString)
                    HStack(spacing: 10) {
                        AssetThumbnail(ref: AssetEditing.thumbnail(of: asset, in: content), images: images, size: 32,
                                       ring: model.selectedAsset == asset.id ? color : Crayon.ink.opacity(0.18))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(asset.name).font(Crayon.font(.body, weight: .semibold)).lineLimit(1)
                            HStack(spacing: 4) {
                                Circle().fill(color).frame(width: 6, height: 6).accessibilityHidden(true)
                                Text(AssetEditing.typeTitle(asset.type)).font(.caption).foregroundStyle(Crayon.inkSoft)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                    .tag(asset.id)
                }
            }
            .scrollContentBackground(.hidden)
            .overlay {
                if assets.isEmpty {
                    CrayonEmptyState(AssetEditing.emptyListTitle(filter: model.typeFilter),
                                     systemImage: "person.crop.square", color: Crayon.grape,
                                     message: AssetEditing.emptyListMessage(filter: model.typeFilter))
                }
            }
        }
        .alert("New \(newType.map(AssetEditing.typeTitle) ?? "Asset")", isPresented: $newType.isPresent()) {
            TextField("Name", text: $newName)
            Button("Create") { if let type = newType { model.create(type, name: newName, in: document) } }
                .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {}
        }
    }
}

/// The Assets tab's detail: the selected asset's editor.
struct AssetsDetail: View {
    let document: BookDocument
    let content: BookContent
    let model: AssetsModel
    let images: ImageCache
    let onOpenPage: (PageID, BoxID?) -> Void

    var body: some View {
        if let id = model.selectedAsset, let asset = content.assets[id] {
            AssetEditor(document: document, content: content, asset: asset, images: images, model: model,
                        onOpenPage: onOpenPage)
                .id(id)
        } else {
            CrayonEmptyState("No Asset Selected", systemImage: "person.crop.square", color: Crayon.grape,
                             message: "Choose an asset, or add one with +.")
        }
    }
}
