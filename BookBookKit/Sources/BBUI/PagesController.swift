import BBLayout
import BBModel
import BBStore
import Foundation
import Observation

// MARK: - Overview rows (pure)

/// Which part of a page a slot of the overview shows.
public enum OverviewPart: Hashable, Sendable {
    /// A single page (or the cover).
    case single
    /// A spread's left half, on the right of an opening: the spread is split across sheets.
    case splitLeftHalf
    /// A spread's right half, on the left of the next opening (split).
    case splitRightHalf
}

/// One side of an opening: empty, or (part of) a page.
public struct OverviewSlot: Hashable, Sendable {
    public var pageID: PageID?
    public var part: OverviewPart
    /// The physical position (0 = cover), or nil for an empty slot.
    public var position: Int?

    public static let empty = OverviewSlot(pageID: nil, part: .single, position: nil)
}

/// One row of the spread overview (PD §8.5): the cover alone, then page 1 on the right, then
/// facing pairs. A spread that fills both sides of its opening is `spread`.
public struct OverviewRow: Hashable, Sendable, Identifiable {
    public var id: Int
    public var isCover: Bool
    public var left: OverviewSlot
    public var right: OverviewSlot
    /// Set when one spread page fills both sides.
    public var spread: PageID?
}

/// Pure helpers behind the Pages overview: rows, drag-and-drop orders, insertion points and
/// template choices. No views, no document.
public enum PagesOverviewModel {
    /// The sequencer's entries for the book's story pages (a page is a spread when its
    /// template is `.spread`).
    public static func entries(_ content: BookContent) -> [SequenceEntry] {
        content.storyPages.map {
            SequenceEntry(id: $0.id, isSpread: content.template(for: $0)?.kind == .spread)
        }
    }

    public static func layout(_ content: BookContent) -> SequenceLayout {
        PageSequencer.layout(entries(content), cover: content.book.coverPageID)
    }

    /// The overview's rows from `SequenceLayout.openings`.
    public static func rows(_ content: BookContent) -> [OverviewRow] {
        rows(layout(content))
    }

    public static func rows(_ layout: SequenceLayout) -> [OverviewRow] {
        let spans = Dictionary(layout.pages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return layout.openings.enumerated().map { index, opening in
            if opening.isCover {
                return OverviewRow(id: index, isCover: true, left: .empty,
                                   right: OverviewSlot(pageID: opening.right, part: .single, position: 0))
            }
            // Opening 1 holds position 1 on the right; opening k ≥ 2 holds (2k-2, 2k-1).
            let rightPosition = index == 1 ? 1 : 2 * index - 1
            let leftPosition = index == 1 ? nil : 2 * index - 2
            if let left = opening.left, left == opening.right {
                return OverviewRow(id: index, isCover: false,
                                   left: OverviewSlot(pageID: left, part: .single, position: leftPosition),
                                   right: OverviewSlot(pageID: left, part: .single, position: rightPosition),
                                   spread: left)
            }
            func slot(_ id: PageID?, position: Int?, isLeft: Bool) -> OverviewSlot {
                guard let id, let position else { return .empty }
                let isSpread = (spans[id]?.span ?? 1) == 2
                let part: OverviewPart = isSpread ? (isLeft ? .splitRightHalf : .splitLeftHalf) : .single
                return OverviewSlot(pageID: id, part: part, position: position)
            }
            return OverviewRow(id: index, isCover: false,
                               left: slot(opening.left, position: leftPosition, isLeft: true),
                               right: slot(opening.right, position: rightPosition, isLeft: false))
        }
    }

    /// The page-order index for a page inserted after `selection`: right after a story page,
    /// first after the cover, and at the end with no selection.
    public static func insertionIndex(after selection: PageID?, in content: BookContent) -> Int {
        let order = content.book.pageOrder
        if selection == content.book.coverPageID { return 0 }
        guard let selection, let index = order.firstIndex(of: selection) else { return order.count }
        return index + 1
    }

    /// The order after dropping `moving` onto `target`: the moved page takes the target's
    /// place (after it when moving forward, before it when moving back). Nil when nothing
    /// would change or either page isn't in `order`.
    public static func order(moving: PageID, onto target: PageID, in order: [PageID]) -> [PageID]? {
        guard moving != target, let from = order.firstIndex(of: moving), let to = order.firstIndex(of: target)
        else { return nil }
        var result = order
        result.remove(at: from)
        // After removal, the target's index shifts down by one when it was after `from`.
        let targetIndex = result.firstIndex(of: target)!
        result.insert(moving, at: to > from ? targetIndex + 1 : targetIndex)
        return result == order ? nil : result
    }

    /// The order after dropping `moving` past the last page.
    public static func order(movingToEnd moving: PageID, in order: [PageID]) -> [PageID]? {
        guard let from = order.firstIndex(of: moving), from != order.count - 1 else { return nil }
        var result = order
        result.remove(at: from)
        result.append(moving)
        return result
    }

    /// Templates offered for a page: `.cover` templates for the cover, `.single`/`.spread`
    /// otherwise. The bundled presets first (the book's own copy when it has one), in preset
    /// order, then the book's other templates by name.
    public static func templateChoices(forCover: Bool, in content: BookContent,
                                       presets: [Template]) -> [Template] {
        func fits(_ t: Template) -> Bool { forCover ? t.kind == .cover : t.kind != .cover }
        var seen = Set<TemplateID>()
        var result: [Template] = []
        for preset in presets where fits(preset) && seen.insert(preset.id).inserted {
            result.append(content.templates[preset.id] ?? preset)
        }
        let others = content.templates.values.filter { fits($0) && !seen.contains($0.id) }
            .sorted { ($0.name, $0.id.rawValue.uuidString) < ($1.name, $1.id.rawValue.uuidString) }
        return result + others
    }

    /// Label for a physical position in the overview ("Cover", "1", "2"…), using the page
    /// numbers' start number.
    public static func positionLabel(_ position: Int?, startNumber: Int) -> String? {
        guard let position else { return nil }
        return position == 0 ? "Cover" : String(startNumber + position - 1)
    }
}

// MARK: - fixSplits

extension BookCommand {
    /// The same command with `fixSplits` set (unchanged for non-structural commands).
    public func withFixSplits(_ fix: Bool) -> BookCommand {
        switch self {
        case let .addPage(index, templateID, _): .addPage(index: index, templateID: templateID, fixSplits: fix)
        case let .duplicatePage(id, _): .duplicatePage(id, fixSplits: fix)
        case let .deletePage(id, _): .deletePage(id, fixSplits: fix)
        case let .reorderPages(order, _): .reorderPages(order, fixSplits: fix)
        case let .setPageTemplate(page, templateID, _): .setPageTemplate(page: page, templateID: templateID, fixSplits: fix)
        case let .importStoryText(texts, templateID, index, _):
            .importStoryText(texts, templateID: templateID, index: index, fixSplits: fix)
        case .setRichText, .setTypography, .chooseVersion, .setPageDone, .setPageNumberStyle,
             .addTemplate, .updateTemplate, .deleteTemplate, .setStyleVisual, .setPageSetup, .markFlagsOK, .setCrop: self
        }
    }

    /// Commands that can change the page sequence (and so may split a spread).
    public var isStructural: Bool {
        switch self {
        case .addPage, .duplicatePage, .deletePage, .reorderPages, .setPageTemplate, .importStoryText: true
        case .setRichText, .setTypography, .chooseVersion, .setPageDone, .setPageNumberStyle,
             .addTemplate, .updateTemplate, .deleteTemplate, .setStyleVisual, .setPageSetup, .markFlagsOK, .setCrop: false
        }
    }
}

// MARK: - Controller

/// The Pages tab's state and page operations for one book window: selection, overview or
/// editor mode, the open sheet, and the spread-split warning (PD §8.5). Every edit goes
/// through `perform` (a `BookCommand`). Not a view, so it's testable with closures.
@MainActor @Observable
public final class PagesController {
    public enum Mode: Hashable, Sendable { case overview, editor }

    public enum Sheet: Hashable, Identifiable, Sendable {
        /// Template picker for a new page inserted at `index`.
        case addPage(index: Int)
        /// Template picker for changing a page's layout.
        case changeLayout(PageID)
        case importStory
        case bookSettings
        case pageNumbers

        public var id: Self { self }
    }

    /// How the user answered the spread-split warning.
    public enum SplitChoice: Sendable { case insertBlankPage, moveAnyway, cancel }

    public var mode: Mode = .overview
    public var selectedPage: PageID?
    public var sheet: Sheet?
    /// A structural command waiting on the spread-split warning (sent with `fixSplits: false`).
    public private(set) var pendingSplit: BookCommand?

    @ObservationIgnored private let content: @MainActor () -> BookContent
    @ObservationIgnored private let performCommand: @MainActor (BookCommand) -> Bool
    @ObservationIgnored private let wouldSplit: @MainActor (BookCommand) -> Bool
    @ObservationIgnored private let editable: @MainActor () -> Bool

    public init(content: @escaping @MainActor () -> BookContent, perform: @escaping @MainActor (BookCommand) -> Bool,
                wouldSplitSpread: @escaping @MainActor (BookCommand) -> Bool,
                isEditable: @escaping @MainActor () -> Bool = { true }) {
        self.content = content
        self.performCommand = perform
        self.wouldSplit = wouldSplitSpread
        self.editable = isEditable
    }

    public convenience init(document: BookDocument) {
        self.init(content: { [unowned document] in document.content },
                  perform: { [unowned document] in document.perform($0) },
                  wouldSplitSpread: { [unowned document] in document.wouldSplitSpread($0) },
                  isEditable: { [unowned document] in document.isEditable })
    }

    public var isEditable: Bool { editable() }

    /// Work to run once the open sheet has gone (so a split warning can be presented).
    @ObservationIgnored private var afterSheet: (@MainActor () -> Void)?

    /// Closes the sheet, then runs `action` (the window calls `sheetDidDismiss()`).
    public func dismissSheet(then action: @escaping @MainActor () -> Void) {
        afterSheet = action
        sheet = nil
    }

    public func sheetDidDismiss() {
        let action = afterSheet
        afterSheet = nil
        action?()
    }

    public var showsSplitWarning: Bool { pendingSplit != nil }

    // MARK: Queries

    public func isCover(_ page: PageID?) -> Bool { page != nil && page == content().book.coverPageID }

    public func isStoryPage(_ page: PageID?) -> Bool {
        guard let page else { return false }
        return content().book.pageOrder.contains(page)
    }

    public func isDone(_ page: PageID) -> Bool { content().pages[page]?.isDone ?? false }

    public func isNumberSkipped(_ page: PageID) -> Bool {
        content().style.pageNumbers.skippedPages.contains(page)
    }

    /// Where a new page goes: after the selection (first after the cover), else at the end.
    public var insertionIndex: Int { PagesOverviewModel.insertionIndex(after: selectedPage, in: content()) }

    // MARK: Navigation

    public func open(_ page: PageID) {
        selectedPage = page
        mode = .editor
    }

    /// Keeps the selection valid after an undo or redo changed the pages.
    public func validateSelection() {
        let c = content()
        if let page = selectedPage, c.pages[page] != nil,
           page == c.book.coverPageID || c.book.pageOrder.contains(page) { return }
        selectedPage = c.book.pageOrder.first ?? c.book.coverPageID
    }

    // MARK: Operations

    /// Sends a command, first showing the spread-split warning when it would split a spread.
    /// Returns true if it was performed now.
    @discardableResult
    public func request(_ command: BookCommand) -> Bool {
        guard isEditable else { return false }
        let plain = command.withFixSplits(false)
        if plain.isStructural, wouldSplit(plain) {
            pendingSplit = plain
            return false
        }
        return run(plain)
    }

    /// Resolves the spread-split warning.
    public func resolveSplit(_ choice: SplitChoice) {
        guard let command = pendingSplit else { return }
        pendingSplit = nil
        switch choice {
        case .insertBlankPage: run(command.withFixSplits(true))
        case .moveAnyway: run(command.withFixSplits(false))
        case .cancel: break
        }
    }

    public func addPage(templateID: TemplateID, at index: Int) {
        request(.addPage(index: index, templateID: templateID))
    }

    public func duplicate(_ page: PageID) {
        guard isStoryPage(page) else { return }
        request(.duplicatePage(page))
    }

    public func delete(_ page: PageID) {
        guard isStoryPage(page) else { return }
        request(.deletePage(page))
    }

    public func changeLayout(_ page: PageID, to templateID: TemplateID) {
        guard content().pages[page]?.templateID != templateID else { return }
        request(.setPageTemplate(page: page, templateID: templateID))
    }

    public func toggleDone(_ page: PageID) {
        guard isEditable, content().pages[page] != nil else { return }
        run(.setPageDone(page, !isDone(page)))
    }

    public func toggleSkipNumber(_ page: PageID) {
        guard isEditable, isStoryPage(page) else { return }
        var style = content().style.pageNumbers
        if style.skippedPages.contains(page) { style.skippedPages.remove(page) } else { style.skippedPages.insert(page) }
        run(.setPageNumberStyle(style))
    }

    public func setPageNumberStyle(_ style: PageNumberStyle) {
        guard isEditable, style != content().style.pageNumbers else { return }
        run(.setPageNumberStyle(style))
    }

    /// Drag and drop: `moving` takes `target`'s place.
    public func move(_ moving: PageID, onto target: PageID) {
        guard let order = PagesOverviewModel.order(moving: moving, onto: target, in: content().book.pageOrder)
        else { return }
        selectedPage = moving
        request(.reorderPages(order))
    }

    public func moveToEnd(_ moving: PageID) {
        guard let order = PagesOverviewModel.order(movingToEnd: moving, in: content().book.pageOrder) else { return }
        selectedPage = moving
        request(.reorderPages(order))
    }

    /// Imports story pages after the selection (or at the end) as one command.
    public func importStory(_ texts: [RichText], templateID: TemplateID) {
        guard !texts.isEmpty else { return }
        request(.importStoryText(texts, templateID: templateID, index: insertionIndex))
    }

    // MARK: Performing

    @discardableResult
    private func run(_ command: BookCommand) -> Bool {
        let before = content()
        guard performCommand(command) else { return false }
        updateSelection(after: command, before: before)
        return true
    }

    private func updateSelection(after command: BookCommand, before: BookContent) {
        let after = content()
        let old = Set(before.book.pageOrder)
        let added = after.book.pageOrder.filter { !old.contains($0) }
        func firstAdded(using templateID: TemplateID?) -> PageID? {
            added.first { after.pages[$0]?.templateID == templateID } ?? added.first
        }
        switch command {
        case let .addPage(_, templateID, _), let .importStoryText(_, templateID, _, _):
            if let page = firstAdded(using: templateID) { selectedPage = page }
        case let .duplicatePage(source, _):
            if let page = firstAdded(using: before.pages[source]?.templateID) { selectedPage = page }
        case let .deletePage(page, _):
            if selectedPage == page {
                selectedPage = PageListing.selectionAfterDeleting(page, in: before)
                    .flatMap { after.pages[$0] != nil ? $0 : nil }
            }
        default:
            break
        }
        validateSelection()
    }
}
