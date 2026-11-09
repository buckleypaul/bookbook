import BBModel
import SwiftUI

/// A chosen-image thumbnail, or an empty state.
struct AssetThumbnail: View {
    let ref: ImageRef?
    let images: ImageCache
    var size: CGFloat = 56

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(.quaternary)
            if let ref, let cg = images.image(for: ref) {
                Image(decorative: cg, scale: 1).resizable().scaledToFill()
            } else {
                Image(systemName: "photo").foregroundStyle(.tertiary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// The character sheet grid (PD §8.3): turnaround views and expressions.
struct CharacterSheetView: View {
    let document: BookDocument
    let content: BookContent
    let asset: Asset
    let images: ImageCache
    let model: AssetsModel
    let onGenerate: () -> Void
    @State private var addingExpression = false
    @State private var expressionName = ""

    private var editable: Bool { document.isEditable }

    var body: some View {
        let items = asset.sheet?.items ?? []
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Character Sheet").font(.headline)
                Spacer()
                Button("Add Expression…") { expressionName = ""; addingExpression = true }
                    .disabled(!editable)
                Button("Generate Whole Sheet…", action: onGenerate)
                    .disabled(!editable)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 10)], alignment: .leading, spacing: 10) {
                ForEach(items) { item in cell(item) }
            }
        }
        .alert("Add Expression", isPresented: $addingExpression) {
            TextField("Name", text: $expressionName)
            Button("Add") { model.update(asset, in: document, actionName: "Add Expression") {
                AssetEditing.addExpression(expressionName, to: &$0) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("For example: grumpy, giggling.")
        }
    }

    private func cell(_ item: SheetItem) -> some View {
        let owner = SessionOwner.sheetItem(asset.id, item.id)
        let selected = model.selectedOwner == owner
        return VStack(spacing: 4) {
            AssetThumbnail(ref: AssetEditing.chosenImage(sessionID: item.sessionID, chosen: item.chosen, in: content),
                           images: images, size: 96)
            Text(AssetEditing.title(of: item.kind)).font(.callout).lineLimit(1)
            if item.chosen == nil { Text("Empty").font(.caption).foregroundStyle(.secondary) }
            HStack(spacing: 6) {
                Toggle(isOn: Binding(get: { item.locked }, set: { locked in
                    model.update(asset, in: document, actionName: locked ? "Lock Sheet Item" : "Unlock Sheet Item") {
                        AssetEditing.setLocked(locked, item: item.id, in: &$0)
                    }
                })) { Image(systemName: item.locked ? "lock.fill" : "lock.open") }
                    .toggleStyle(.button)
                    .buttonStyle(.borderless)
                    .help(item.locked ? "Locked: skipped by Generate Whole Sheet" : "Lock to keep this item")
                    .disabled(!editable)
                Button { model.update(asset, in: document, actionName: "Remove Sheet Item") {
                    AssetEditing.removeSheetItem(item.id, from: &$0) } } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
                    .help("Remove from sheet")
                    .disabled(!editable)
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity)
        .background(selected ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture { model.selectedOwner = owner }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(AssetEditing.title(of: item.kind))
    }
}
