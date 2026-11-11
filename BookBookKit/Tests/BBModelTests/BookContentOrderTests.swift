import Foundation
import Testing
@testable import BBModel

@Suite struct BookContentOrderTests {
    private func book(pages: Int) -> BookContent {
        let story = Template(name: "Story", kind: .single, boxes: [])
        let cover = Template(name: "Cover", kind: .cover, boxes: [])
        return BookContent.makeNew(title: "T", storyTemplate: story, coverTemplate: cover, storyPageCount: pages,
                                   now: Date(timeIntervalSince1970: 0))
    }

    @Test func pageIDsCoverFirst_coverThenReadingOrder() {
        var content = book(pages: 3)
        #expect(content.pageIDsCoverFirst == [content.book.coverPageID] + content.book.pageOrder)
        // A cover listed in the page order still comes first, once.
        content.book.pageOrder.insert(content.book.coverPageID, at: 1)
        let story = content.book.pageOrder.filter { $0 != content.book.coverPageID }
        #expect(content.pageIDsCoverFirst == [content.book.coverPageID] + story)
    }
}
