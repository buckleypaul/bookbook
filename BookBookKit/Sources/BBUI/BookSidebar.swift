import BBModel
import BBStore
import SwiftUI

/// The page list: the cover, then story pages in reading order. Click selects; double-click
/// opens the page editor; right-click for page commands (including delete); the + row under the
/// last page inserts a page after the selection (all undoable).
struct PageList: View {
    let document: BookDocument
    let content: BookContent
    let pages: PagesController
    let thumbnails: PageThumbnailRenderer
    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorScheme) private var colorScheme

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
    /// and layout name. The selected one is filled tomato and lifts on a deeper shadow; its text
    /// and thumbnail rim follow the `CrayonContrast` label rule (as crayon buttons do).
    private func row(_ title: String, page: PageID, status: PageStatus, flags: ImageFlags,
                     selected: Bool) -> some View {
        let tile = RoundedRectangle(cornerRadius: Crayon.smallCornerRadius, style: .continuous)
        let layoutName = content.pages[page].flatMap { content.templates[$0.templateID]?.name }
        return HStack(spacing: 8) {
            thumbnail(page, selected: selected)
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(Crayon.font(.body, weight: .bold))
                    .foregroundStyle(selected ? selectedLabel : Crayon.ink)
                if let layoutName {
                    Text(layoutName)
                        .font(Crayon.font(.caption, weight: .semibold))
                        .foregroundStyle(selected ? selectedLabel : Crayon.inkSoft)
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

    /// Text and rims on the selected row's tomato fill: white or `Crayon.onFill`, whichever
    /// reaches 4.5:1 (`onFill` in both appearances today).
    private var selectedLabel: Color {
        CrayonContrast.label(on: Crayon.tomato, preferring: .white, minimum: CrayonContrast.text, in: colorScheme)
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
                        shape.strokeBorder(selected ? selectedLabel : Crayon.ink.opacity(0.15),
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
struct SidebarTabPicker: View {
    @Binding var selection: SidebarTab
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tile = RoundedRectangle(cornerRadius: Crayon.thumbCornerRadius, style: .continuous)
        HStack(spacing: 3) {
            ForEach(SidebarTab.allCases) { tab in
                let selected = selection == tab
                Button { selection = tab } label: {
                    Image(systemName: tab.symbol)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        // On its fill, the glyph follows the `CrayonContrast` rule for icons.
                        .foregroundStyle(selected
                                         ? CrayonContrast.label(on: tab.crayonColor, preferring: .white,
                                                                minimum: CrayonContrast.graphics, in: colorScheme)
                                         : tab.crayonColor)
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
struct PagesModePicker: View {
    @Binding var selection: PagesController.Mode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

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
                .foregroundStyle(selected
                                 ? CrayonContrast.label(on: Crayon.tomato, preferring: .white,
                                                        minimum: CrayonContrast.text, in: colorScheme)
                                 : Crayon.ink)
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
struct OfflineBadge: View {
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
