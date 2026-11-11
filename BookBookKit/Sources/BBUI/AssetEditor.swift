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

    /// Assets of `type` (all when nil), by name.
    static func list(_ content: BookContent, type: AssetType?) -> [Asset] {
        content.assets.values.filter { type == nil || $0.type == type }
            .sorted {
                let order = $0.name.localizedCaseInsensitiveCompare($1.name)
                return order == .orderedSame ? $0.id.rawValue.uuidString < $1.id.rawValue.uuidString
                    : order == .orderedAscending
            }
    }

    /// The asset's image: its chosen version's picture (nil when nothing is chosen, or the
    /// session or version is gone).
    static func image(of asset: Asset, in content: BookContent) -> ImageRef? {
        guard let chosen = asset.chosen else { return nil }
        return content.sessions[asset.sessionID]?.version(chosen)?.image
    }

    /// The thumbnail shown everywhere for an asset: its image.
    static func thumbnail(of asset: Asset, in content: BookContent) -> ImageRef? {
        image(of: asset, in: content)
    }

    /// The large image's empty placeholder text.
    static func emptyImageMessage(for asset: Asset) -> String {
        "Describe \(asset.name) below and press Generate, or import an image file."
    }

    /// What the description is for, under its header.
    static func descriptionHelp(for asset: Asset) -> String {
        "What \(asset.name) looks like. Generate draws \(asset.name) from this and the style guide, "
            + "and pages that mention or tick \(asset.name) get this text along with the picture."
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
    /// Called with the draft as it's typed (before it's committed).
    var onDraftChange: ((String) -> Void)?
    @State private var draft = ""
    /// The last value `draft` was brought in line with; only a draft that differs from it is committed.
    @State private var synced = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if multiline {
                TextEditor(text: $draft)
                    .font(.body)
                    .frame(minHeight: 70)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Crayon.paper,
                                in: RoundedRectangle(cornerRadius: Crayon.smallCornerRadius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Crayon.smallCornerRadius, style: .continuous)
                        .strokeBorder(focused ? Crayon.tomato.opacity(0.7) : Crayon.ink.opacity(0.12),
                                      lineWidth: focused ? 2 : 1.5))
            } else {
                TextField(title, text: $draft).onSubmit(flush)
            }
        }
        .focused($focused)
        .onAppear { draft = value; synced = value }
        // An outside change (an undo while focused) wins over a stale draft.
        .onChange(of: value) { _, new in synced = new; draft = new }
        .onChange(of: draft) { _, new in onDraftChange?(new) }
        .onChange(of: focused) { _, now in if !now { flush() } }
        .onDisappear(perform: flush)
        .accessibilityLabel(title)
    }

    private func flush() {
        if let text = CommittedText.textToCommit(draft: draft, synced: synced) { commit(text) }
    }
}

/// The pure rule behind `CommittedTextField`.
enum CommittedText {
    /// The draft to commit, or nil when it equals what the field last synced with (nothing was typed).
    static func textToCommit(draft: String, synced: String) -> String? {
        draft == synced ? nil : draft
    }
}

/// The asset editor (PD §8.3): the asset's large image, name, type, the description with
/// Generate / Regenerate (a fresh picture from the description) and Import Image…, the image's
/// details, where used and delete.
struct AssetEditor: View {
    let document: BookDocument
    let content: BookContent
    let asset: Asset
    let images: ImageCache
    let model: AssetsModel
    let onOpenPage: (PageID, BoxID?) -> Void
    @State private var confirmDelete = false
    /// The description as typed; Generate commits it first.
    @State private var descriptionDraft: String?
    @State private var detailsExpanded = false

    private var editable: Bool { document.isEditable }

    var body: some View {
        let sites = document.usageSites(of: asset.id)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                AssetImageCard(asset: asset, image: AssetEditing.image(of: asset, in: content), images: images,
                               color: color)
                header
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        CrayonHeader("Description", color: Crayon.sky)
                        Text(AssetEditing.descriptionHelp(for: asset))
                            .font(Crayon.font(.caption, weight: .medium))
                            .foregroundStyle(Crayon.inkSoft)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    CommittedTextField(title: "Description", value: asset.description, multiline: true,
                                       commit: commitDescription, onDraftChange: { descriptionDraft = $0 })
                    AssetImageControls(document: document, content: content, asset: asset,
                                       description: descriptionDraft ?? asset.description,
                                       commitDescription: { if let descriptionDraft { commitDescription(descriptionDraft) } })
                }
                .crayonCard(padding: 14)
                imageDetails
                VStack(alignment: .leading, spacing: 8) {
                    CrayonHeader("Where Used", color: Crayon.grass)
                    WhereUsedList(sites: sites, content: content, onOpen: onOpenPage)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .crayonCard(padding: 14)
                Button("Delete Asset…", role: .destructive) { confirmDelete = true }
                    .buttonBorderShape(.capsule)
                    .disabled(!editable)
            }
            .padding(16)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .crayonPaper()
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

    /// The asset's own colour: its image frame, sticker and selection wash.
    private var color: Color { Crayon.color(forKey: asset.id.rawValue.uuidString) }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            CommittedTextField(title: "Name", value: asset.name) { text in
                let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                model.update(asset, in: document, actionName: "Rename Asset") { $0.name = name }
            }
            .font(Crayon.font(.title2, weight: .bold))
            AssetTypeChip(type: asset.type, color: color)
        }
    }

    private func commitDescription(_ text: String) {
        model.update(asset, in: document, actionName: "Edit Description") { $0.description = text }
    }

    /// Version details (what was sent to the provider) for the asset's current image.
    @ViewBuilder
    private var imageDetails: some View {
        if let id = asset.chosen, let session = content.sessions[asset.sessionID],
           let version = session.version(id) {
            DisclosureGroup(isExpanded: $detailsExpanded) {
                VersionDetailsGrid(version: version, session: session, bookID: document.id, assets: content.assets)
            } label: {
                Text("Image details")
                    .font(Crayon.font(.subheadline, weight: .bold))
                    .foregroundStyle(Crayon.ink)
            }
            .crayonCard(padding: 14)
        }
    }
}

/// The asset's one image, large, in a card framed in the asset's colour; or a friendly
/// placeholder pointing at the description and Generate.
private struct AssetImageCard: View {
    let asset: Asset
    let image: ImageRef?
    let images: ImageCache
    let color: Color
    @State private var preview: CGImage?

    var body: some View {
        let cg = image.flatMap { images.image(for: $0) }
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: Crayon.cornerRadius, style: .continuous)
                    .fill(Crayon.paperDeep)
                if let cg {
                    Image(decorative: cg, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: Crayon.smallCornerRadius, style: .continuous))
                        .padding(8)
                        .accessibilityLabel("\(asset.name)'s image")
                        .onTapGesture(count: 2) { preview = cg }
                        .contextMenu {
                            Button("View Larger", systemImage: "arrow.up.left.and.arrow.down.right") { preview = cg }
                        }
                } else {
                    VStack(spacing: 12) {
                        CrayonBlobIcon(systemImage: AssetEditing.typeSymbol(asset.type), color: color, size: 64)
                        Text("No Picture Yet")
                            .font(Crayon.font(.title3, weight: .bold))
                            .foregroundStyle(Crayon.ink)
                        Text(AssetEditing.emptyImageMessage(for: asset))
                            .font(Crayon.font(.callout, weight: .medium))
                            .foregroundStyle(Crayon.inkSoft)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 340)
                    }
                    .padding(24)
                    .accessibilityElement(children: .combine)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 240, maxHeight: 420)
            .overlay(RoundedRectangle(cornerRadius: Crayon.cornerRadius, style: .continuous)
                .strokeBorder(color.opacity(cg == nil ? 0.35 : 0.8),
                              style: StrokeStyle(lineWidth: 3, dash: cg == nil ? [8, 6] : [])))
            if let cg {
                HStack {
                    Spacer()
                    Button("View Larger", systemImage: "arrow.up.left.and.arrow.down.right") { preview = cg }
                        .buttonBorderShape(.capsule)
                }
            }
        }
        .sheet(item: Binding(get: { preview.map(PreviewItem.init) }, set: { preview = $0?.image })) { item in
            ImagePreviewSheet(title: asset.name, image: item.image)
        }
    }

    private struct PreviewItem: Identifiable {
        let image: CGImage
        var id: ObjectIdentifier { ObjectIdentifier(image) }
    }
}

/// The asset's type as a sticker-like chip in the asset's colour: a solid symbol badge and ink
/// text on a soft wash, so it stays legible for every colour in both appearances.
private struct AssetTypeChip: View {
    let type: AssetType
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: AssetEditing.typeSymbol(type))
                .font(.caption2.weight(.heavy))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(color))
                .accessibilityHidden(true)
            Text(AssetEditing.typeTitle(type))
                .font(Crayon.font(.caption, weight: .heavy))
                .foregroundStyle(Crayon.ink)
        }
        .padding(.leading, 3)
        .padding(.trailing, 9)
        .padding(.vertical, 3)
        .background(Capsule().fill(Crayon.card).shadow(color: Crayon.shadow, radius: 0, x: 0, y: 1.5))
        .background(Capsule().fill(color.opacity(0.18)))
        .overlay(Capsule().strokeBorder(color.opacity(0.55), lineWidth: 1.5))
    }
}
