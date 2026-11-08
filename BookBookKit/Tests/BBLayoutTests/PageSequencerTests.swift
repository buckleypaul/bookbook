import BBModel
import Testing
@testable import BBLayout

@Suite struct PageSequencerTests {
    private func entries(_ spreads: [Bool]) -> [SequenceEntry] {
        spreads.map { SequenceEntry(id: PageID(), isSpread: $0) }
    }

    @Test func emptyBookHasOnlyCoverOpening() {
        let cover = PageID()
        let layout = PageSequencer.layout([], cover: cover)
        #expect(layout.pages.isEmpty)
        #expect(layout.openings == [Opening(left: nil, right: cover, isCover: true)])
    }

    @Test func singlesPairAfterRightHandPageOne() {
        let cover = PageID()
        let e = entries([false, false, false])
        let layout = PageSequencer.layout(e, cover: cover)
        #expect(layout.pages.map(\.position) == [1, 2, 3])
        #expect(layout.openings.count == 3)
        #expect(layout.openings[1] == Opening(left: nil, right: e[0].id))
        #expect(layout.openings[2] == Opening(left: e[1].id, right: e[2].id))
        #expect(!layout.hasSplitSpread)
    }

    @Test func finalOddLeftLeavesRightNil() {
        let e = entries([false, false])
        let layout = PageSequencer.layout(e, cover: PageID())
        #expect(layout.openings.last == Opening(left: e[1].id, right: nil))
    }

    @Test func spreadAtPositionOneIsSplit() {
        let e = entries([true, false])
        let layout = PageSequencer.layout(e, cover: PageID())
        #expect(layout.pages[0].isSplit)
        #expect(layout.pages[0].span == 2)
        #expect(layout.pages[1].position == 3)
        #expect(layout.hasSplitSpread)
        #expect(layout.openings[1] == Opening(left: nil, right: e[0].id))
        #expect(layout.openings[2] == Opening(left: e[0].id, right: e[1].id))
    }

    @Test func spreadOnEvenPositionIsWhole() {
        let e = entries([false, true])
        let layout = PageSequencer.layout(e, cover: PageID())
        #expect(!layout.pages[1].isSplit)
        #expect(layout.openings[2] == Opening(left: e[1].id, right: e[1].id))
    }

    @Test func blankInsertionExamples() {
        #expect(PageSequencer.blankInsertions(for: entries([false, true])).isEmpty)
        #expect(PageSequencer.blankInsertions(for: entries([true])) == [0])
        // single, single, spread (starts at 3, odd) -> blank before index 2; then spread, spread fine.
        #expect(PageSequencer.blankInsertions(for: entries([false, false, true, true])) == [2])
        // Two split spreads in a row: the first blank fixes the second.
        #expect(PageSequencer.blankInsertions(for: entries([true, true])) == [0])
    }

    /// Every order of up to 8 entries with every spread/single mix.
    @Test func exhaustiveInvariants() {
        let cover = PageID()
        for n in 0...8 {
            for mask in 0..<(1 << n) {
                let order = (0..<n).map { SequenceEntry(id: PageID(), isSpread: mask & (1 << $0) != 0) }
                check(order, cover: cover)
            }
        }
    }

    private func check(_ order: [SequenceEntry], cover: PageID) {
        let layout = PageSequencer.layout(order, cover: cover)

        // Contiguous positions from 1, spans match, split flag matches parity.
        var expected = 1
        for (entry, page) in zip(order, layout.pages) {
            #expect(page.id == entry.id)
            #expect(page.position == expected)
            #expect(page.span == (entry.isSpread ? 2 : 1))
            #expect(page.isSplit == (entry.isSpread && expected % 2 == 1))
            expected += page.span
        }

        // Openings agree with positions.
        #expect(layout.openings.first?.isCover == true)
        var occupant: [Int: PageID] = [:]
        for page in layout.pages { for p in page.position..<(page.position + page.span) { occupant[p] = page.id } }
        let total = expected - 1
        if total == 0 {
            #expect(layout.openings.count == 1)
        } else {
            #expect(layout.openings.count == 2 + total / 2)
            #expect(layout.openings[1] == Opening(left: nil, right: occupant[1]))
            for k in 2..<layout.openings.count {
                let left = 2 * (k - 1)
                #expect(layout.openings[k].left == occupant[left])
                #expect(layout.openings[k].right == occupant[left + 1])
            }
        }

        // Applying the insertions removes every split, and uses one blank per originally split
        // spread that is still split at its turn (minimal for the strategy).
        let insertions = PageSequencer.blankInsertions(for: order)
        var grown = order
        var blanks = Set<PageID>()
        for i in insertions {
            let blank = SequenceEntry(id: PageID(), isSpread: false)
            blanks.insert(blank.id)
            grown.insert(blank, at: i)
        }
        #expect(insertions == insertions.sorted())
        #expect(!PageSequencer.layout(grown, cover: cover).hasSplitSpread)
        #expect(grown.filter { !blanks.contains($0.id) }.map(\.id) == order.map(\.id))
        if !layout.hasSplitSpread { #expect(insertions.isEmpty) }
        // Each blank sits directly before a spread.
        for i in insertions { #expect(grown[i + 1].isSpread) }
        // Minimal: removing any one blank splits something again.
        for blank in blanks {
            let without = grown.filter { $0.id != blank }
            #expect(PageSequencer.layout(without, cover: cover).hasSplitSpread)
        }
    }
}
