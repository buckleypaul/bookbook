import BBModel
import SwiftUI

/// A chosen-image thumbnail, or an empty state.
struct AssetThumbnail: View {
    let ref: ImageRef?
    let images: ImageCache
    var size: CGFloat = 56
    /// A coloured avatar ring around the thumbnail (the asset's colour); nil for none.
    var ring: Color?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: min(Crayon.smallCornerRadius + 2, size * 0.28), style: .continuous)
        ZStack {
            shape.fill(Crayon.paperDeep)
            if let ref, let cg = images.image(for: ref) {
                Image(decorative: cg, scale: 1).resizable().scaledToFill()
            } else {
                Image(systemName: "photo").foregroundStyle(Crayon.inkSoft.opacity(0.7))
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay {
            if let ring {
                shape.strokeBorder(ring, lineWidth: size >= 48 ? 3 : 2).padding(-(size >= 48 ? 3 : 2))
            }
        }
        .padding(ring == nil ? 0 : (size >= 48 ? 3 : 2))
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
                CrayonHeader("Character Sheet", color: Crayon.bubblegum)
                Spacer()
                Button("Add Expression…") { expressionName = ""; addingExpression = true }
                    .buttonBorderShape(.capsule)
                    .disabled(!editable)
                Button("Generate Whole Sheet…", action: onGenerate)
                    .buttonStyle(.crayon(Crayon.grape))
                    .disabled(!editable)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 12)], alignment: .leading, spacing: 12) {
                ForEach(items) { item in cell(item) }
            }
            .padding(.vertical, 4)
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
        let color = Crayon.color(forKey: asset.id.rawValue.uuidString)
        return VStack(spacing: 4) {
            AssetThumbnail(ref: AssetEditing.chosenImage(sessionID: item.sessionID, chosen: item.chosen, in: content),
                           images: images, size: 96)
            Text(AssetEditing.title(of: item.kind)).font(Crayon.font(.callout, weight: .bold))
                .foregroundStyle(Crayon.ink).lineLimit(1)
            if item.chosen == nil {
                Text("Empty").font(Crayon.font(.caption, weight: .medium)).foregroundStyle(Crayon.inkSoft)
            }
            HStack(spacing: 6) {
                Toggle(isOn: Binding(get: { item.locked }, set: { locked in
                    model.update(asset, in: document, actionName: locked ? "Lock Sheet Item" : "Unlock Sheet Item") {
                        AssetEditing.setLocked(locked, item: item.id, in: &$0)
                    }
                })) {
                    Image(systemName: item.locked ? "lock.fill" : "lock.open")
                        .foregroundStyle(item.locked ? Crayon.tomato : Crayon.inkSoft)
                }
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
        .frame(maxWidth: .infinity)
        .crayonCard(selected: selected, tint: color, cornerRadius: Crayon.cornerRadius - 2, padding: 8)
        .crayonHover(tilt: -1.5, scale: 1.03)
        .contentShape(Rectangle())
        .onTapGesture { model.selectedOwner = owner }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(AssetEditing.title(of: item.kind))
    }
}
