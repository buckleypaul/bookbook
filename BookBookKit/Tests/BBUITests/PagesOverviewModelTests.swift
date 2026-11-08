import BBLayout
import BBModel
import Foundation
import Testing
@testable import BBUI

/// The Pages overview's pure model and `PagesController`, with a fake `perform` (the real
/// Phase 5 commands are lane L3's).
@MainActor
struct PagesOverviewModelTests {
    static let spreadTemplate = Template(name: "Spread", kind: .spread, boxes: [Fixtures.imageBox])

    /// A book with `kinds` story pages (true = spread).
    private func book(_ kinds: [Bool]) -> BookContent {
        var content = Fixtures.book(pages: 0)
        content.templates[Self.spreadTemplate.id] = Self.spreadTemplate
        for isSpread in kinds {
            let page = Page(kind: .story, templateID: isSpread ? Self.spreadTemplate.id : Fixtures.storyTemplate.id)
            content.pages[page.id] = page
            content.book.pageOrder.append(page.id)
        }
        return content
    }

    // MARK: Rows

    @Test func rows_coverAloneThenPageOneOnTheRightThenPairs() {
        let content = book([false, false, false, false])
        let order = content.book.pageOrder
        let rows = PagesOverviewModel.rows(content)
        #expect(rows.count == 4)
        #expect(rows[0].isCover && rows[0].left == .empty && rows[0].right.pageID == content.book.coverPageID)
        #expect(rows[0].right.position == 0)
        #expect(rows[1].left == .empty && rows[1].right.pageID == order[0] && rows[1].right.position == 1)
        #expect(rows[2].left.pageID == order[1] && rows[2].right.pageID == order[2])
        #expect(rows[2].left.position == 2 && rows[2].right.position == 3)
        #expect(rows[3].left.pageID == order[3] && rows[3].right == .empty)
        #expect(rows.allSatisfy { $0.spread == nil })
    }

    @Test func rows_spreadOnEvenPositionFillsOneOpening() {
        let content = book([false, true])
        let rows = PagesOverviewModel.rows(content)
        #expect(rows.count == 3)
        #expect(rows[2].spread == content.book.pageOrder[1])
        #expect(rows[2].left.position == 2 && rows[2].right.position == 3)
    }

    @Test func rows_splitSpreadShowsItsHalvesAcrossTwoOpenings() {
        let content = book([true])
        let spread = content.book.pageOrder[0]
        let rows = PagesOverviewModel.rows(content)
        #expect(rows.count == 3)
        #expect(rows[1].right == OverviewSlot(pageID: spread, part: .splitLeftHalf, position: 1))
        #expect(rows[2].left == OverviewSlot(pageID: spread, part: .splitRightHalf, position: 2))
        #expect(rows[1].spread == nil && rows[2].spread == nil)
    }

    @Test func rows_emptyBookHasOnlyTheCover() {
        let rows = PagesOverviewModel.rows(book([]))
        #expect(rows.count == 1 && rows[0].isCover)
    }

    @Test func positionLabel_usesStartNumber() {
        #expect(PagesOverviewModel.positionLabel(0, startNumber: 5) == "Cover")
        #expect(PagesOverviewModel.positionLabel(1, startNumber: 1) == "1")
        #expect(PagesOverviewModel.positionLabel(3, startNumber: 5) == "7")
        #expect(PagesOverviewModel.positionLabel(nil, startNumber: 1) == nil)
    }

    // MARK: Drag-and-drop orders

    @Test func order_movingForwardLandsAfterTarget() {
        let ids = (0..<4).map { _ in PageID() }
        #expect(PagesOverviewModel.order(moving: ids[0], onto: ids[2], in: ids) == [ids[1], ids[2], ids[0], ids[3]])
    }

    @Test func order_movingBackLandsBeforeTarget() {
        let ids = (0..<4).map { _ in PageID() }
        #expect(PagesOverviewModel.order(moving: ids[3], onto: ids[1], in: ids) == [ids[0], ids[3], ids[1], ids[2]])
    }

    @Test func order_isAlwaysAPermutation() {
        let ids = (0..<6).map { _ in PageID() }
        for a in ids {
            for b in ids {
                guard let result = PagesOverviewModel.order(moving: a, onto: b, in: ids) else {
                    #expect(a == b)
                    continue
                }
                #expect(Set(result) == Set(ids) && result.count == ids.count)
                #expect(result.firstIndex(of: a) == ids.firstIndex(of: b))
            }
        }
    }

    @Test func order_invalidOrUnchangedIsNil() {
        let ids = (0..<3).map { _ in PageID() }
        #expect(PagesOverviewModel.order(moving: ids[0], onto: ids[0], in: ids) == nil)
        #expect(PagesOverviewModel.order(moving: PageID(), onto: ids[0], in: ids) == nil)
        #expect(PagesOverviewModel.order(movingToEnd: ids[2], in: ids) == nil)
        #expect(PagesOverviewModel.order(movingToEnd: ids[0], in: ids) == [ids[1], ids[2], ids[0]])
    }

    // MARK: Insertion and templates

    @Test func insertionIndex_afterStoryPageFirstAfterCoverElseEnd() {
        let content = book([false, false, false])
        let order = content.book.pageOrder
        #expect(PagesOverviewModel.insertionIndex(after: order[1], in: content) == 2)
        #expect(PagesOverviewModel.insertionIndex(after: content.book.coverPageID, in: content) == 0)
        #expect(PagesOverviewModel.insertionIndex(after: nil, in: content) == 3)
        #expect(PagesOverviewModel.insertionIndex(after: nil, in: book([])) == 0)
    }

    @Test func templateChoices_coverGetsCoverTemplatesOnly_storyGetsSingleAndSpread() {
        let content = book([])
        var edited = Fixtures.storyTemplate
        edited.name = "Book's own copy"
        var withCopy = content
        withCopy.templates[edited.id] = edited
        let extraPreset = Template(name: "Preset only", kind: .single, boxes: [])
        let coverPreset = Template(name: "Cover preset", kind: .cover, boxes: [])
        let presets = [Fixtures.storyTemplate, coverPreset, extraPreset]

        let story = PagesOverviewModel.templateChoices(forCover: false, in: withCopy, presets: presets)
        #expect(story.map(\.id) == [Fixtures.storyTemplate.id, extraPreset.id, Self.spreadTemplate.id])
        #expect(story[0].name == "Book's own copy")

        let cover = PagesOverviewModel.templateChoices(forCover: true, in: withCopy, presets: presets)
        #expect(cover.map(\.id) == [coverPreset.id, Fixtures.coverTemplate.id])
    }

    @Test func withFixSplits_setsTheFlagOnStructuralCommandsOnly() {
        let page = PageID(), template = TemplateID()
        #expect(BookCommand.deletePage(page).withFixSplits(true) == .deletePage(page, fixSplits: true))
        #expect(BookCommand.reorderPages([page], fixSplits: true).withFixSplits(false) == .reorderPages([page]))
        #expect(BookCommand.importStoryText([], templateID: template, index: 2).withFixSplits(true)
                == .importStoryText([], templateID: template, index: 2, fixSplits: true))
        #expect(BookCommand.setPageDone(page, true).withFixSplits(true) == .setPageDone(page, true))
        #expect(!BookCommand.setPageDone(page, true).isStructural)
        #expect(BookCommand.setPageTemplate(page: page, templateID: template).isStructural)
    }
}

/// `PagesController` against a fake document.
@MainActor
struct PagesControllerTests {
    final class FakeDocument {
        var content: BookContent
        var performed: [BookCommand] = []
        var splits = false
        var editable = true
        init(_ content: BookContent) { self.content = content }

        /// Applies the commands the controller sends, enough to check selection.
        func perform(_ command: BookCommand) -> Bool {
            performed.append(command)
            switch command {
            case let .addPage(index, templateID, _):
                let page = Page(kind: .story, templateID: templateID)
                content.pages[page.id] = page
                content.book.pageOrder.insert(page.id, at: min(index, content.book.pageOrder.count))
            case let .duplicatePage(source, _):
                guard let i = content.book.pageOrder.firstIndex(of: source), let original = content.pages[source]
                else { return false }
                var copy = original
                copy.id = PageID()
                content.pages[copy.id] = copy
                content.book.pageOrder.insert(copy.id, at: i + 1)
            case let .deletePage(page, _):
                content.book.pageOrder.removeAll { $0 == page }
                content.pages[page] = nil
            case let .reorderPages(order, _):
                content.book.pageOrder = order
            case let .importStoryText(texts, templateID, index, _):
                for (offset, text) in texts.enumerated() {
                    let page = Page(kind: .story, templateID: templateID, text: [Fixtures.textBox.id: text])
                    content.pages[page.id] = page
                    content.book.pageOrder.insert(page.id, at: index + offset)
                }
            case let .setPageDone(page, done):
                content.pages[page]?.isDone = done
            case let .setPageNumberStyle(style):
                content.style.pageNumbers = style
            default:
                break
            }
            return true
        }
    }

    private func make(pages: Int = 3) -> (PagesController, FakeDocument) {
        let doc = FakeDocument(Fixtures.book(pages: pages))
        let controller = PagesController(content: { doc.content }, perform: { doc.perform($0) },
                                         wouldSplitSpread: { _ in doc.splits }, isEditable: { doc.editable })
        return (controller, doc)
    }

    @Test func request_withoutSplit_performsPlainCommand() {
        let (pages, doc) = make()
        let page = doc.content.book.pageOrder[0]
        #expect(pages.request(.deletePage(page, fixSplits: true)))
        #expect(doc.performed == [.deletePage(page)])
        #expect(pages.pendingSplit == nil)
    }

    @Test func splitWarning_insertBlankPage_sendsFixSplitsTrue() {
        let (pages, doc) = make()
        doc.splits = true
        let order = Array(doc.content.book.pageOrder.reversed())
        #expect(!pages.request(.reorderPages(order)))
        #expect(pages.showsSplitWarning && doc.performed.isEmpty)
        pages.resolveSplit(.insertBlankPage)
        #expect(doc.performed == [.reorderPages(order, fixSplits: true)])
        #expect(!pages.showsSplitWarning)
    }

    @Test func splitWarning_moveAnyway_sendsFixSplitsFalse_cancelSendsNothing() {
        let (pages, doc) = make()
        doc.splits = true
        let page = doc.content.book.pageOrder[1]
        pages.duplicate(page)
        pages.resolveSplit(.moveAnyway)
        #expect(doc.performed == [.duplicatePage(page)])
        pages.delete(page)
        pages.resolveSplit(.cancel)
        #expect(doc.performed.count == 1)
        #expect(pages.pendingSplit == nil)
    }

    @Test func nonStructuralCommandsSkipTheWarning() {
        let (pages, doc) = make()
        doc.splits = true
        let page = doc.content.book.pageOrder[0]
        pages.toggleDone(page)
        pages.toggleSkipNumber(page)
        #expect(doc.content.pages[page]?.isDone == true)
        #expect(doc.content.style.pageNumbers.skippedPages == [page])
        pages.toggleSkipNumber(page)
        #expect(doc.content.style.pageNumbers.skippedPages.isEmpty)
        #expect(!pages.showsSplitWarning)
    }

    @Test func readOnly_sendsNothing() {
        let (pages, doc) = make()
        doc.editable = false
        pages.addPage(templateID: Fixtures.storyTemplate.id, at: 0)
        pages.toggleDone(doc.content.book.pageOrder[0])
        #expect(doc.performed.isEmpty)
    }

    @Test func coverCantBeDeletedDuplicatedOrMoved() {
        let (pages, doc) = make()
        let cover = doc.content.book.coverPageID
        pages.delete(cover)
        pages.duplicate(cover)
        pages.toggleSkipNumber(cover)
        pages.move(cover, onto: doc.content.book.pageOrder[0])
        #expect(doc.performed.isEmpty)
        #expect(pages.isCover(cover) && !pages.isStoryPage(cover))
    }

    @Test func addAfterSelection_selectsTheNewPage() {
        let (pages, doc) = make()
        pages.selectedPage = doc.content.book.pageOrder[0]
        pages.addPage(templateID: Fixtures.storyTemplate.id, at: pages.insertionIndex)
        #expect(doc.performed == [.addPage(index: 1, templateID: Fixtures.storyTemplate.id)])
        #expect(pages.selectedPage == doc.content.book.pageOrder[1])
    }

    @Test func duplicate_selectsTheCopy() {
        let (pages, doc) = make()
        let source = doc.content.book.pageOrder[2]
        pages.selectedPage = source
        pages.duplicate(source)
        #expect(pages.selectedPage == doc.content.book.pageOrder[3])
    }

    @Test func deleteSelected_selectsNextThenPreviousThenCover() {
        let (pages, doc) = make(pages: 2)
        let order = doc.content.book.pageOrder
        pages.selectedPage = order[0]
        pages.delete(order[0])
        #expect(pages.selectedPage == order[1])
        pages.delete(order[1])
        #expect(pages.selectedPage == doc.content.book.coverPageID)
    }

    @Test func move_reordersAndKeepsTheMovedPageSelected() {
        let (pages, doc) = make(pages: 4)
        let order = doc.content.book.pageOrder
        pages.move(order[3], onto: order[0])
        #expect(doc.performed == [.reorderPages([order[3], order[0], order[1], order[2]])])
        #expect(pages.selectedPage == order[3])
        pages.moveToEnd(order[3])
        #expect(doc.content.book.pageOrder == order)
    }

    @Test func importStory_afterCoverInEmptyBook_isOneCommandAtIndexZero() {
        let (pages, doc) = make(pages: 0)
        pages.selectedPage = doc.content.book.coverPageID
        let texts = ["One", "Two", "Three"].map { RichText(plain: $0) }
        pages.importStory(texts, templateID: Fixtures.storyTemplate.id)
        #expect(doc.performed == [.importStoryText(texts, templateID: Fixtures.storyTemplate.id, index: 0)])
        #expect(doc.content.book.pageOrder.count == 3)
        #expect(pages.selectedPage == doc.content.book.pageOrder[0])
    }

    @Test func importStory_noSelection_appendsAtEnd() {
        let (pages, doc) = make(pages: 2)
        pages.selectedPage = nil
        pages.importStory([RichText(plain: "x")], templateID: Fixtures.storyTemplate.id)
        #expect(doc.performed == [.importStoryText([RichText(plain: "x")], templateID: Fixtures.storyTemplate.id,
                                                   index: 2)])
    }

    @Test func validateSelection_afterUndoRemovesSelectedPage() {
        let (pages, doc) = make(pages: 2)
        let order = doc.content.book.pageOrder
        pages.selectedPage = order[1]
        doc.content.book.pageOrder.removeLast()
        doc.content.pages[order[1]] = nil
        pages.validateSelection()
        #expect(pages.selectedPage == order[0])
    }

    @Test func pageNumberStyle_unchangedSendsNothing() {
        let (pages, doc) = make()
        pages.setPageNumberStyle(doc.content.style.pageNumbers)
        #expect(doc.performed.isEmpty)
        var style = doc.content.style.pageNumbers
        style.enabled = true
        style.startNumber = 3
        pages.setPageNumberStyle(style)
        #expect(doc.performed == [.setPageNumberStyle(style)])
    }

    @Test func dismissSheet_runsActionAfterDismissal() {
        let (pages, doc) = make()
        pages.sheet = .importStory
        pages.dismissSheet { pages.addPage(templateID: Fixtures.storyTemplate.id, at: 0) }
        #expect(pages.sheet == nil && doc.performed.isEmpty)
        pages.sheetDidDismiss()
        #expect(doc.performed.count == 1)
        pages.sheetDidDismiss()
        #expect(doc.performed.count == 1)
    }
}

/// Story import sheet model (splitting itself is tested in BBLayoutTests).
@MainActor
struct StoryImportModelTests {
    @Test func pastedText_blankLines_andMarker() {
        let model = StoryImportModel(templateID: Fixtures.storyTemplate.id)
        model.pastedText = "One.\n\nTwo.\r\n\r\nThree."
        #expect(model.pages.map(\.plainText) == ["One.", "Two.", "Three."])
        #expect(model.canImport)
        model.rule = .marker
        model.pastedText = "One.\n\nStill one.\n---\nTwo."
        #expect(model.pages.count == 2)
        model.marker = "  "
        #expect(model.splitRule == .marker("---"))
        model.marker = "***"
        #expect(model.pages.count == 1)
    }

    @Test func emptyTextOrNoTemplate_cantImport() {
        let model = StoryImportModel(templateID: nil)
        model.pastedText = "Words"
        #expect(!model.canImport)
        model.templateID = Fixtures.storyTemplate.id
        model.pastedText = "  \n\n "
        #expect(model.pages.isEmpty && !model.canImport)
    }

    @Test func openingAFile_keepsItsRichTextUntilTheUserTypes() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "StoryImport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "story.txt")
        try Data("A\n\nB".utf8).write(to: url)
        let model = StoryImportModel(templateID: Fixtures.storyTemplate.id)
        model.open(url, typography: StyleGuide().typography)
        #expect(model.fileName == "story.txt")
        #expect(model.pages.count == 2)
        model.pastedText += "\n\nC"
        #expect(model.fileName == nil)
        #expect(model.pages.count == 3)

        let bad = dir.appending(path: "story.doc")
        try Data("x".utf8).write(to: bad)
        model.open(bad, typography: StyleGuide().typography)
        #expect(model.readError != nil)
    }

    @Test func previewLine_joinsLines() {
        #expect(StoryImportModel.previewLine(RichText(plain: "a\nb")) == "a b")
    }
}
