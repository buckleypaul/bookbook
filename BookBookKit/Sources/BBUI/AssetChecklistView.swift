import BBModel
import SwiftUI

/// The page's asset checklist (PD §8.6): every asset in the book with a checkbox. Ticked
/// assets travel with every request from the page's boxes. Each toggle is one undoable
/// `setAssetChecklist`.
struct AssetChecklistView: View {
    let document: BookDocument
    let content: BookContent
    let pageID: PageID
    @State private var expanded = false

    private var checklist: [AssetID] { content.pages[pageID]?.assetChecklist ?? [] }

    var body: some View {
        let assets = content.assets.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let ticked = checklist.filter { content.assets[$0] != nil }.count
        DisclosureGroup(isExpanded: $expanded) {
            if assets.isEmpty {
                Text("No assets yet. Add characters, places and objects in the Assets tab.")
                    .font(.caption).foregroundStyle(Crayon.inkSoft)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(assets) { asset in
                        Toggle(isOn: Binding(get: { checklist.contains(asset.id) },
                                             set: { toggle(asset.id, on: $0) })) {
                            Label {
                                Text(asset.name).foregroundStyle(Crayon.ink)
                            } icon: {
                                Image(systemName: AssetTypeText.symbol(asset.type))
                                    .fontWeight(.semibold)
                                    .foregroundStyle(Crayon.color(forKey: asset.id.rawValue.uuidString))
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                .padding(.top, 4)
            }
        } label: {
            HStack(spacing: 6) {
                Circle().fill(Crayon.grass).frame(width: 8, height: 8).accessibilityHidden(true)
                Text(ticked == 0 ? "Assets on this page" : "Assets on this page (\(ticked))")
                    .font(Crayon.font(.headline, weight: .heavy))
                    .foregroundStyle(Crayon.ink)
            }
        }
    }

    private func toggle(_ id: AssetID, on: Bool) {
        let list = AssetChecklistEdit.toggled(checklist, id, on: on)
        document.perform(.setAssetChecklist(page: pageID, list))
    }
}

enum AssetChecklistEdit {
    /// The checklist with `id` added at the end or removed (order kept).
    static func toggled(_ list: [AssetID], _ id: AssetID, on: Bool) -> [AssetID] {
        on ? (list.contains(id) ? list : list + [id]) : list.filter { $0 != id }
    }
}
