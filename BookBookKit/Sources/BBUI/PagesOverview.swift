import BBLayout
import BBModel
import BBStore
import SwiftUI

/// The Pages tab's spread overview (PD §8.5): the cover alone, then page 1 on the right, then
/// facing pairs, each page with a status badge. Click selects, double-click opens the page
/// editor, drag-and-drop reorders (with the spread-split warning), right-click for page
/// commands.
struct PagesOverview: View {
    let document: BookDocument
    let pages: PagesController
    let thumbnails: PageThumbnailRenderer
    @Binding var showNumbers: Bool
    @Environment(\.displayScale) private var displayScale
    @State private var dropTarget: PageID?
    @State private var endIsTargeted = false

    static let pageHeight: CGFloat = 160

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
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: side.width * 2 + 8), spacing: 36)],
                      alignment: .leading, spacing: 24) {
                ForEach(rows) { row in
                    rowView(row, context)
                }
                endDropZone(side)
            }
            .padding(24)
        }
        // No rigid minimum: the window minimum leaves the detail column almost nothing when
        // the session panel is shown (`BookWindow.minimumWidth`); narrower, the grid clips.
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .clipped()
        .background(Color(nsColor: .underPageBackgroundColor))
        .onDeleteCommand {
            if let page = pages.selectedPage { pages.delete(page) }
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
        .accessibilityElement(children: .contain)
        .accessibilityLabel(row.isCover ? "Cover" : "Opening \(row.id)")
    }

    @ViewBuilder
    private func slotView(_ slot: OverviewSlot, _ ctx: RowContext) -> some View {
        if let page = slot.pageID {
            pageCell(page, part: slot.part, sides: 1,
                     label: PagesOverviewModel.positionLabel(slot.position, startNumber: ctx.startNumber), ctx)
        } else {
            Color.clear.frame(width: ctx.side.width, height: ctx.side.height + 18)
        }
    }

    private func pageCell(_ pageID: PageID, part: OverviewPart, sides: Int, label: String?,
                          _ ctx: RowContext) -> some View {
        let content = ctx.content
        let page = content.pages[pageID]
        let marks = PageNumbering.marks(for: pageID, layout: ctx.layout, numbers: ctx.numbers)
        let image = thumbnails.image(for: pageID, in: content, marks: marks,
                                     pixelHeight: Int(Self.pageHeight * max(1, displayScale)))
        let isStory = content.book.pageOrder.contains(pageID)
        let canDrag = isStory && document.isEditable
        return PageThumbnailView(image: image, part: part, sideSize: ctx.side, sides: sides,
                                 status: page.map { content.status(of: $0) },
                                 label: showNumbers || label == "Cover" ? label : nil,
                                 isSelected: pages.selectedPage == pageID,
                                 isDropTarget: dropTarget == pageID)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { pages.open(pageID) }
            .simultaneousGesture(TapGesture().onEnded { pages.selectedPage = pageID })
            .contextMenu { PageContextMenu(pages: pages, page: pageID) }
            .modifier(PageDragDrop(pageID: pageID, canDrag: canDrag, canDrop: isStory && document.isEditable,
                                   dropTarget: $dropTarget) { moving in
                pages.move(moving, onto: pageID)
            })
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel(pageID, label: label, content))
            .accessibilityAddTraits(pages.selectedPage == pageID ? [.isSelected, .isButton] : .isButton)
            .accessibilityAction { pages.selectedPage = pageID }
            .accessibilityAction(named: "Open in Editor") { pages.open(pageID) }
    }

    private func accessibilityLabel(_ pageID: PageID, label: String?, _ content: BookContent) -> String {
        guard let page = content.pages[pageID] else { return "" }
        let name = pageID == content.book.coverPageID ? "Cover" : "Page \(label ?? "")"
        let status = switch content.status(of: page) {
        case .empty: "empty"
        case .inProgress: "in progress"
        case .done: "done"
        }
        return "\(name), \(status)"
    }

    /// Dropping here moves a page to the end of the book.
    private func endDropZone(_ side: CGSize) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .strokeBorder(style: StrokeStyle(lineWidth: endIsTargeted ? 3 : 1, dash: [5]))
            .foregroundStyle(endIsTargeted ? Color.accentColor : Color.secondary.opacity(0.4))
            .overlay {
                Button {
                    pages.sheet = .addPage(index: document.content.book.pageOrder.count)
                } label: {
                    Label("Add Page", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .disabled(!document.isEditable)
            }
            .frame(width: side.width, height: side.height)
            .padding(.bottom, 18)
            .dropDestination(for: String.self) { items, _ in
                guard document.isEditable, let moving = items.first.flatMap(PageDragDrop.pageID(from:)) else { return false }
                pages.moveToEnd(moving)
                return true
            } isTargeted: { endIsTargeted = $0 }
            .help("Add a page at the end, or drop a page here to move it to the end")
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

/// The page commands, for the overview's and the page list's context menus.
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
        Button("Duplicate") { pages.duplicate(page) }
            .disabled(!editable || !story)
        Button("Delete") { pages.delete(page) }
            .disabled(!editable || !story)
        Divider()
        Button(pages.isDone(page) ? "Mark as Not Done" : "Mark as Done") { pages.toggleDone(page) }
            .disabled(!editable)
        Button("Change Layout…") {
            pages.selectedPage = page
            pages.sheet = .changeLayout(page)
        }
        .disabled(!editable)
        Button(pages.isNumberSkipped(page) ? "Show Page Number" : "Skip Page Number") { pages.toggleSkipNumber(page) }
            .disabled(!editable || !story)
    }
}
