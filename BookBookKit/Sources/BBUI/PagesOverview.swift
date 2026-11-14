import BBLayout
import BBModel
import BBStore
import SwiftUI

/// The Pages tab's spread overview (PD §8.5): the cover alone, then page 1 on the right, then
/// facing pairs, each page with a status badge. Click selects, double-click (or Return) opens
/// the page editor, the arrow keys move the selection, drag-and-drop reorders (with the
/// spread-split warning), right-click for page commands.
struct PagesOverview: View {
    let document: BookDocument
    let pages: PagesController
    let thumbnails: PageThumbnailRenderer
    /// The Page Labels toggle: the position captions ("Cover", "1", "2"…) under the pages. The
    /// page numbers printed on the pages stay in the art either way.
    @Binding var showLabels: Bool
    @Environment(\.displayScale) private var displayScale
    @State private var dropTarget: PageID?
    @State private var endIsTargeted = false
    @FocusState private var isFocused: Bool

    /// Small enough that two portrait spreads sit side by side at the default window width
    /// (1200 pt leaves the detail card about 630 pt).
    static let pageHeight: CGFloat = 144
    /// Room inside each opening's card around its pages.
    private static let cardPadding: CGFloat = 12
    private static let gridSpacing: CGFloat = 28
    /// The label row under each page (status and position), with the gap above it.
    private static let labelRow = PageThumbnailView.labelSpacing + PageThumbnailView.labelRowHeight

    var body: some View {
        let content = document.content
        let layout = PagesOverviewModel.layout(content)
        let rows = PagesOverviewModel.rows(layout)
        let style = content.style.pageNumbers
        let roles = content.pages.compactMapValues { content.template(for: $0)?.pageRole }
        let numbers = PageNumbering.numbers(layout: layout, style: style, pageRoles: roles)
        let side = sideSize(content)
        let context = RowContext(content: content, layout: layout, numbers: numbers, side: side,
                                 startNumber: style.startNumber)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: side.width * 2 + 8 + Self.cardPadding * 2),
                                             spacing: Self.gridSpacing)],
                          alignment: .leading, spacing: Self.gridSpacing) {
                    ForEach(rows) { row in
                        rowView(row, context).id(row.id)
                    }
                    endDropZone(side)
                }
                .padding(24)
            }
            // The toggle sits on its own strip under the grid, so it never covers a card.
            .safeAreaInset(edge: .bottom, spacing: 0) { labelsBar }
            // No rigid minimum: at the window minimum the detail card gets only
            // `EditorPanelMetrics.detailMin`; narrower content clips.
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            .clipped()
            .background(Crayon.paper)
            // Keyboard: arrows move the selection through the pages, Return opens it, Delete
            // deletes it. The selection ring shows where focus is, so no focus ring.
            .focusable()
            .focused($isFocused)
            .focusEffectDisabled()
            .onMoveCommand { direction in moveSelection(direction, rows: rows, proxy: proxy) }
            .onKeyPress(.return) {
                guard let page = pages.selectedPage else { return .ignored }
                pages.open(page)
                return .handled
            }
            .onDeleteCommand {
                if let page = pages.selectedPage { pages.delete(page) }
            }
        }
    }

    private var labelsBar: some View {
        HStack {
            Spacer()
            Toggle(isOn: $showLabels) { Label("Page Labels", systemImage: "number") }
                .toggleStyle(CrayonChipToggleStyle())
                .help(showLabels ? "Hide page labels" : "Show page labels")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Crayon.paper)
        .overlay(alignment: .top) {
            Rectangle().fill(Crayon.ink.opacity(0.08)).frame(height: 1)
        }
    }

    /// Left / up: the previous page in reading order; right / down: the next. Scrolls the
    /// page's opening into view.
    private func moveSelection(_ direction: MoveCommandDirection, rows: [OverviewRow], proxy: ScrollViewProxy) {
        let step = direction == .left || direction == .up ? -1 : (direction == .right || direction == .down ? 1 : 0)
        guard step != 0,
              let page = PagesOverviewModel.page(step, from: pages.selectedPage, in: document.content)
        else { return }
        pages.selectedPage = page
        if let row = rows.first(where: { $0.left.pageID == page || $0.right.pageID == page }) {
            proxy.scrollTo(row.id)
        }
    }

    private struct RowContext {
        var content: BookContent
        var layout: SequenceLayout
        var numbers: [Int: String]
        var side: CGSize
        var startNumber: Int
    }

    private func sideSize(_ content: BookContent) -> CGSize {
        let trim = content.style.pageSetup.trimSize
        let aspect = trim.height > 0 ? trim.width / trim.height : 0.75
        return CGSize(width: (Self.pageHeight * aspect).rounded(), height: Self.pageHeight)
    }

    @ViewBuilder
    private func rowView(_ row: OverviewRow, _ ctx: RowContext) -> some View {
        HStack(spacing: 0) {
            if let spread = row.spread {
                let label = [row.left.position, row.right.position]
                    .compactMap { PagesOverviewModel.positionLabel($0, startNumber: ctx.startNumber) }
                    .joined(separator: "–")
                pageCell(spread, part: .single, sides: 2, label: label, ctx)
            } else {
                slotView(row.left, ctx)
                slotView(row.right, ctx)
            }
        }
        // Each opening is a card on the paper; the page art inside is untouched.
        .crayonCard(padding: Self.cardPadding)
        .crayonHover(tilt: -1, scale: 1.02)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(row.isCover ? "Cover" : "Opening \(row.id)")
    }

    @ViewBuilder
    private func slotView(_ slot: OverviewSlot, _ ctx: RowContext) -> some View {
        if let page = slot.pageID {
            pageCell(page, part: slot.part, sides: 1,
                     label: PagesOverviewModel.positionLabel(slot.position, startNumber: ctx.startNumber), ctx)
        } else {
            // The empty side of an opening (inside the cover): a soft paper well.
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Crayon.paperDeep)
                .frame(width: ctx.side.width, height: ctx.side.height)
                .padding(.bottom, Self.labelRow)
        }
    }

    private func pageCell(_ pageID: PageID, part: OverviewPart, sides: Int, label: String?,
                          _ ctx: RowContext) -> some View {
        let content = ctx.content
        let page = content.pages[pageID]
        let marks = PageNumbering.marks(for: pageID, layout: ctx.layout, numbers: ctx.numbers)
        let image = thumbnails.image(for: pageID, in: content, marks: marks,
                                     pixelHeight: Int(Self.pageHeight * max(1, displayScale)),
                                     fontsRevision: document.fontsRevision)
        let isStory = content.book.pageOrder.contains(pageID)
        let canDrag = isStory && document.isEditable
        return PageThumbnailView(image: image, part: part, sideSize: ctx.side, sides: sides,
                                 status: page.map { content.status(of: $0) },
                                 flags: page.map { content.imageFlags(of: $0) } ?? [],
                                 label: showLabels || label == "Cover" ? label : nil,
                                 isSelected: pages.selectedPage == pageID,
                                 isDropTarget: dropTarget == pageID)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { pages.open(pageID) }
            .simultaneousGesture(TapGesture().onEnded {
                pages.selectedPage = pageID
                isFocused = true
            })
            .contextMenu {
                PageContextMenu(pages: pages, page: pageID)
            }
            .modifier(PageDragDrop(pageID: pageID, canDrag: canDrag, canDrop: isStory && document.isEditable,
                                   dropTarget: $dropTarget) { moving in
                pages.move(moving, onto: pageID)
            })
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.accessibilityLabel(pageID, part: part, label: label, content))
            .accessibilityAddTraits(pages.selectedPage == pageID ? [.isSelected, .isButton] : .isButton)
            .accessibilityAction { pages.selectedPage = pageID }
            .accessibilityAction(named: "Open in Editor") { pages.open(pageID) }
    }

    /// A page's VoiceOver label: its name, status, any out-of-date flags, and whether it's half
    /// of a spread split across sheets ("Page 3, in progress, Style changed, split across sheets").
    static func accessibilityLabel(_ pageID: PageID, part: OverviewPart, label: String?,
                                   _ content: BookContent) -> String {
        guard let page = content.pages[pageID] else { return "" }
        let name = pageID == content.book.coverPageID ? "Cover" : label.map { "Page \($0)" } ?? "Page"
        let status = switch content.status(of: page) {
        case .empty: "empty"
        case .inProgress: "in progress"
        case .done: "done"
        }
        var parts = [name, status] + FlagText.entries(content.imageFlags(of: page)).map(\.title)
        if part != .single { parts.append("split across sheets") }
        return parts.joined(separator: ", ")
    }

    /// Dropping here moves a page to the end of the book.
    private func endDropZone(_ side: CGSize) -> some View {
        let shape = RoundedRectangle(cornerRadius: Crayon.cornerRadius, style: .continuous)
        return shape
            .fill(endIsTargeted ? Crayon.sky.opacity(0.15) : Crayon.paperDeep)
            .overlay {
                shape.strokeBorder(style: StrokeStyle(lineWidth: endIsTargeted ? 3 : 2, dash: [7, 5]))
                    .foregroundStyle(endIsTargeted ? Crayon.sky : Crayon.inkSoft.opacity(0.45))
            }
            .overlay {
                Button {
                    pages.sheet = .addPage(index: document.content.book.pageOrder.count)
                } label: {
                    Label("Add Page…", systemImage: "plus")
                }
                .buttonStyle(.crayon)
                .disabled(!document.isEditable)
            }
            // The same size as a one-page opening's card, so the grid stays even.
            .frame(width: side.width + Self.cardPadding * 2, height: side.height + Self.labelRow + Self.cardPadding * 2)
            .crayonHover()
            .dropDestination(for: String.self) { items, _ in
                guard document.isEditable, let moving = items.first.flatMap(PageDragDrop.pageID(from:)) else { return false }
                pages.moveToEnd(moving)
                return true
            } isTargeted: { endIsTargeted = $0 }
            .help("Add a page at the end, or drop a page here to move it to the end")
    }
}

/// An on/off chip for the overview's labels toggle: a pill on a card when off, filled tomato
/// when on, in the Crayon type.
private struct CrayonChipToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Chip(configuration: configuration)
    }

    private struct Chip: View {
        let configuration: Configuration
        @Environment(\.colorScheme) private var colorScheme

        var body: some View {
            let on = configuration.isOn
            let capsule = Capsule(style: .continuous)
            Button { configuration.isOn.toggle() } label: {
                configuration.label
                    .font(Crayon.font(.caption, weight: .bold))
                    // On the tomato fill, the `CrayonContrast` label rule (as crayon buttons).
                    .foregroundStyle(on ? CrayonContrast.label(on: Crayon.tomato, preferring: .white,
                                                               minimum: CrayonContrast.text, in: colorScheme)
                                        : Crayon.ink)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(capsule.fill(on ? Crayon.tomato : Crayon.card)
                        .shadow(color: Crayon.shadow, radius: 0, x: 0, y: 2))
                    .overlay(capsule.strokeBorder(Crayon.ink.opacity(on ? 0 : 0.12), lineWidth: 1))
                    .contentShape(capsule)
            }
            .buttonStyle(.plain)
            .accessibilityValue(on ? "On" : "Off")
            .accessibilityAddTraits(on ? .isSelected : [])
        }
    }
}

/// Makes a page cell draggable (as its ID string) and a drop target for other pages.
struct PageDragDrop: ViewModifier {
    let pageID: PageID
    let canDrag: Bool
    let canDrop: Bool
    @Binding var dropTarget: PageID?
    let onDrop: (PageID) -> Void

    static func pageID(from string: String) -> PageID? {
        UUID(uuidString: string).map(PageID.init(rawValue:))
    }

    func body(content: Content) -> some View {
        if canDrag {
            dropping(content.draggable(pageID.rawValue.uuidString))
        } else {
            dropping(content)
        }
    }

    @ViewBuilder
    private func dropping(_ view: some View) -> some View {
        if canDrop {
            view.dropDestination(for: String.self) { items, _ in
                guard let moving = items.first.flatMap(Self.pageID(from:)), moving != pageID else { return false }
                onDrop(moving)
                return true
            } isTargeted: { targeted in
                if targeted { dropTarget = pageID } else if dropTarget == pageID { dropTarget = nil }
            }
        } else {
            view
        }
    }
}

/// The page commands, for the overview's and the page list's context menus. Named as in the
/// Page menu.
struct PageContextMenu: View {
    let pages: PagesController
    let page: PageID

    var body: some View {
        let story = pages.isStoryPage(page)
        let editable = pages.isEditable
        Button("Open in Editor") { pages.open(page) }
        Divider()
        Button("Insert Page After…") {
            pages.selectedPage = page
            pages.sheet = .addPage(index: pages.insertionIndex)
        }
        .disabled(!editable)
        Button("Duplicate Page") { pages.duplicate(page) }
            .disabled(!editable || !story)
        Button("Delete Page", role: .destructive) { pages.delete(page) }
            .disabled(!editable || !story)
        Divider()
        Button(pages.isDone(page) ? "Mark as Not Done" : "Mark as Done") { pages.toggleDone(page) }
            .disabled(!editable)
        // Enabled only when one of the page's images has an out-of-date flag.
        Button("Mark as OK") { pages.markFlagsOK(page) }
            .disabled(!editable || !pages.hasImageFlags(page))
        Button("Change Layout…") {
            pages.selectedPage = page
            pages.sheet = .changeLayout(page)
        }
        .disabled(!editable)
        Button(pages.isNumberSkipped(page) ? "Show Page Number" : "Skip Page Number") { pages.toggleSkipNumber(page) }
            .disabled(!editable || !story)
    }
}
