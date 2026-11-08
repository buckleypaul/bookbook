import BBModel
import Testing
@testable import BBLayout

@Suite struct PageNumberingTests {
    private let cover = PageID()

    private func make(_ spreads: [Bool]) -> ([SequenceEntry], SequenceLayout) {
        let e = spreads.map { SequenceEntry(id: PageID(), isSpread: $0) }
        return (e, PageSequencer.layout(e, cover: cover))
    }

    @Test func disabledGivesNothing() {
        let (_, layout) = make([false, false])
        #expect(PageNumbering.numbers(layout: layout, style: PageNumberStyle(enabled: false), pageRoles: [:]).isEmpty)
    }

    @Test func numbersFollowPositionsAndSkipCover() {
        let (_, layout) = make([false, false, false])
        let n = PageNumbering.numbers(layout: layout, style: PageNumberStyle(enabled: true), pageRoles: [:])
        #expect(n == [1: "1", 2: "2", 3: "3"])
        #expect(n[0] == nil)
    }

    @Test func startNumberOffsets() {
        let (_, layout) = make([false, false])
        let n = PageNumbering.numbers(layout: layout, style: PageNumberStyle(enabled: true, startNumber: 5), pageRoles: [:])
        #expect(n == [1: "5", 2: "6"])
    }

    @Test func frontMatterSkippedButStillCounted() {
        let (e, layout) = make([false, false, false])
        let roles: [PageID: PageRole] = [e[0].id: .titlePage, e[1].id: .dedication, e[2].id: .theEnd]
        let on = PageNumbering.numbers(layout: layout, style: PageNumberStyle(enabled: true), pageRoles: roles)
        #expect(on == [3: "3"])
        let off = PageNumbering.numbers(layout: layout, style: PageNumberStyle(enabled: true, skipFrontMatter: false),
                                        pageRoles: roles)
        #expect(off.count == 3)
    }

    @Test func skippedPages() {
        let (e, layout) = make([false, false, false])
        let style = PageNumberStyle(enabled: true, skippedPages: [e[1].id])
        let n = PageNumbering.numbers(layout: layout, style: style, pageRoles: [:])
        #expect(n == [1: "1", 3: "3"])
    }

    @Test func spreadsGetTwoNumbers() {
        let (e, layout) = make([false, true, false])
        let n = PageNumbering.numbers(layout: layout, style: PageNumberStyle(enabled: true), pageRoles: [:])
        #expect(n == [1: "1", 2: "2", 3: "3", 4: "4"])
        let marks = PageNumbering.marks(for: e[1].id, layout: layout, numbers: n)
        #expect(marks == [PageNumberMark(text: "2", half: 0, isLeftHand: true),
                          PageNumberMark(text: "3", half: 1, isLeftHand: false)])
    }

    @Test func marksForSingleAndMissing() {
        let (e, layout) = make([false, false])
        let n = PageNumbering.numbers(layout: layout, style: PageNumberStyle(enabled: true, skippedPages: [e[1].id]),
                                      pageRoles: [:])
        #expect(PageNumbering.marks(for: e[0].id, layout: layout, numbers: n)
            == [PageNumberMark(text: "1", half: 0, isLeftHand: false)])
        #expect(PageNumbering.marks(for: e[1].id, layout: layout, numbers: n).isEmpty)
        #expect(PageNumbering.marks(for: PageID(), layout: layout, numbers: n).isEmpty)
    }
}
