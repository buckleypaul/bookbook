import BBModel
import Testing
@testable import BBUI

@MainActor
struct SafeFileNameTests {
    @Test func replacesPathSeparatorsAndFallsBackWhenEmpty() {
        #expect(SafeFileName.make("a/b:c", fallback: "X") == "a-b-c")
        #expect(SafeFileName.make("", fallback: "X") == "X")
        #expect(SafeFileName.make(" ", fallback: "X") == " ")
    }

    @Test func versionExportName() {
        let content = Fixtures.book(pages: 2)
        let page = content.book.pageOrder[1]
        #expect(VersionExport.suggestedName(book: "Fox/Hen: A Tale", page: page, in: content, number: 3,
                                            ref: Fixtures.ref) == "Fox-Hen- A Tale p2 v3.png")
        #expect(VersionExport.suggestedName(book: "", page: content.book.coverPageID, in: content, number: 1,
                                            ref: Fixtures.ref) == "BookBook cover v1.png")
    }
}
