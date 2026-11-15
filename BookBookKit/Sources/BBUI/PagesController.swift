import BBLayout
import BBModel
import BBStore
import Foundation
import Observation

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
        /// Phase 16: import assets, templates and the style guide from another book (PD §8.1).
        case importFromBook

        public var id: Self { self }
    }

    /// How the user answered the spread-split warning.
    public enum SplitChoice: Sendable { case insertBlankPage, moveAnyway, cancel }

    public var mode: Mode = .overview
    /// The book window's sidebar tab. Kept here rather than in the view so that every route to
    /// a page or the overview (the Page menu, the export sheet's preflight links, where-used
    /// links) brings the Pages tab forward: see `open(_:)` and `showOverview()`.
    var sidebarTab: SidebarTab = .pages
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

    /// Whether any of the page's images carries an out-of-date flag (A §4.4), so Mark as OK has
    /// something to clear.
    public func hasImageFlags(_ page: PageID) -> Bool {
        let c = content()
        guard let p = c.pages[page] else { return false }
        return !c.imageFlags(of: p).isEmpty
    }

    /// The overview is on screen: the Pages tab in overview mode.
    public var isShowingOverview: Bool { sidebarTab == .pages && mode == .overview }

    /// The page editor is on screen: the Pages tab in editor mode.
    public var isShowingEditor: Bool { sidebarTab == .pages && mode == .editor }

    /// Where a new page goes: after the selection (first after the cover), else at the end.
    public var insertionIndex: Int { PagesOverviewModel.insertionIndex(after: selectedPage, in: content()) }

    // MARK: Navigation

    /// Opens `page` in the page editor, switching to the Pages tab from any other tab.
    public func open(_ page: PageID) {
        selectedPage = page
        sidebarTab = .pages
        mode = .editor
    }

    /// Shows the spread overview, switching to the Pages tab from any other tab.
    public func showOverview() {
        sidebarTab = .pages
        mode = .overview
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

    /// Mark as OK over all of the page's images (one undoable step).
    public func markFlagsOK(_ page: PageID) {
        guard isEditable, hasImageFlags(page) else { return }
        run(.markFlagsOK(page: page, box: nil))
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
