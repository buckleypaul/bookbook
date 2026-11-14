import BBModel
import BBStore
import Foundation
import Testing
@testable import BBUI

/// Book-window navigation through `PagesController` (opening a page or the overview from any
/// sidebar tab), the page menus' Mark as OK, the overview's keyboard selection and labels, and
/// the locked-book message.
@MainActor
struct PagesNavigationTests {
    private func make(pages: Int = 3) -> (PagesController, PagesControllerTests.FakeDocument) {
        let doc = PagesControllerTests.FakeDocument(Fixtures.book(pages: pages))
        let controller = PagesController(content: { doc.content }, perform: { doc.perform($0) },
                                         wouldSplitSpread: { _ in doc.splits }, isEditable: { doc.editable })
        return (controller, doc)
    }

    @Test func open_fromAnotherTab_showsThePageInTheEditorOnThePagesTab() {
        let (pages, doc) = make()
        let page = doc.content.book.pageOrder[1]
        for tab in SidebarTab.allCases {
            pages.sidebarTab = tab
            pages.mode = .overview
            pages.open(page)
            #expect(pages.sidebarTab == .pages)
            #expect(pages.mode == .editor && pages.selectedPage == page)
            #expect(pages.isShowingEditor && !pages.isShowingOverview)
        }
    }

    @Test func showOverview_fromAnotherTab_switchesToThePagesTab() {
        let (pages, _) = make()
        pages.sidebarTab = .assets
        #expect(!pages.isShowingOverview && !pages.isShowingEditor)
        pages.showOverview()
        #expect(pages.sidebarTab == .pages && pages.mode == .overview)
        #expect(pages.isShowingOverview)
    }

    @Test func markFlagsOK_sendsNothingWithoutFlagsOrWhenReadOnly() {
        let (pages, doc) = make()
        let page = doc.content.book.pageOrder[0]
        #expect(!pages.hasImageFlags(page))
        pages.markFlagsOK(page)
        #expect(doc.performed.isEmpty)
        #expect(!pages.hasImageFlags(PageID()))
    }

    @Test func keyboardSelection_walksCoverThenStoryPages_andStopsAtTheEnds() {
        let (_, doc) = make(pages: 2)
        let content = doc.content
        let cover = content.book.coverPageID
        let order = content.book.pageOrder
        #expect(PagesOverviewModel.page(1, from: nil, in: content) == cover)
        #expect(PagesOverviewModel.page(1, from: cover, in: content) == order[0])
        #expect(PagesOverviewModel.page(1, from: order[0], in: content) == order[1])
        #expect(PagesOverviewModel.page(1, from: order[1], in: content) == order[1])
        #expect(PagesOverviewModel.page(-1, from: order[0], in: content) == cover)
        #expect(PagesOverviewModel.page(-1, from: cover, in: content) == cover)
        #expect(PagesOverviewModel.page(-1, from: PageID(), in: content) == cover)
    }

    @Test func overviewAccessibilityLabel_namesStatusAndSplit() {
        let (_, doc) = make(pages: 1)
        let content = doc.content
        let page = content.book.pageOrder[0]
        let label = PagesOverview.accessibilityLabel(page, part: .single, label: "1", content)
        #expect(label.hasPrefix("Page 1, "))
        #expect(!label.contains("split"))
        let split = PagesOverview.accessibilityLabel(page, part: .splitLeftHalf, label: "1", content)
        #expect(split.hasSuffix(", split across sheets"))
        let cover = PagesOverview.accessibilityLabel(content.book.coverPageID, part: .single, label: "Cover", content)
        #expect(cover.hasPrefix("Cover, "))
    }

    @Test func lockedMessage_namesTheHostOnce() {
        let owner = LockOwner(pid: 1, host: "Studio.local", acquiredAt: Date(), hostID: "AAAA")
        for offers in [true, false] {
            let message = LockTakeOver.message(for: owner, offersOpenAnyway: offers)
            #expect(message.components(separatedBy: "Studio.local").count == 2)
            #expect(!message.contains("Another copy of BookBook"))
            #expect(message.contains("read-only"))
            #expect(message.contains("open it anyway") == offers)
        }
    }
}
