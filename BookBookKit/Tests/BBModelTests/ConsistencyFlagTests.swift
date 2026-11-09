import Foundation
import Testing
@testable import BBModel

struct ConsistencyFlagTests {
    static func report(warns: Bool, dismissed: Bool = false) -> ConsistencyReport {
        ConsistencyReport(checkedAt: StyleFlagsTests.now, provider: .openai, model: "m", consistent: !warns,
                          differences: [], warns: warns, dismissed: dismissed,
                          sent: ConsistencySent(promptSent: "p", imagesSent: []))
    }

    static func book(_ report: ConsistencyReport?) -> (BookContent, PageID, BoxID) {
        var (content, page, box) = StyleFlagsTests.book(provenance: nil)
        let sessionID = content.pages[page]!.images[box]!.sessionID
        content.sessions[sessionID]?.versions[0].consistency = report
        return (content, page, box)
    }

    @Test(arguments: [(true, false, true), (true, true, false), (false, false, false), (false, true, false)])
    func flagFollowsShowsWarning(warns: Bool, dismissed: Bool, expected: Bool) {
        let (content, page, box) = Self.book(Self.report(warns: warns, dismissed: dismissed))
        #expect(content.imageFlags(page: page, box: box).contains(.consistencyWarning) == expected)
        #expect(content.imageFlags(of: content.pages[page]!).contains(.consistencyWarning) == expected)
    }

    @Test func neverCheckedHasNoFlag() {
        let (content, page, box) = Self.book(nil)
        #expect(content.imageFlags(page: page, box: box).isEmpty)
    }

    @Test func emptyBoxHasNoFlag() {
        var (content, page, box) = Self.book(Self.report(warns: true))
        content.pages[page]?.images[box]?.placement = nil
        #expect(content.imageFlags(page: page, box: box).isEmpty)
    }

    @Test func flagCombinesWithOtherFlags() {
        var (content, page, box) = Self.book(Self.report(warns: true))
        content.style.visualRevision = 0
        let flags = content.imageFlags(page: page, box: box)
        #expect(flags == [.consistencyWarning])
    }
}
