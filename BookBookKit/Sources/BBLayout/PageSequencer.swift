import BBModel

/// One entry of the reading order, as the sequencer sees it (A §8.1).
public struct SequenceEntry: Hashable, Sendable {
    public var id: PageID
    public var isSpread: Bool
    public init(id: PageID, isSpread: Bool) {
        self.id = id
        self.isSpread = isSpread
    }
}

/// Where one story page lands physically.
public struct PagePosition: Hashable, Sendable {
    public var id: PageID
    /// First physical position (1 = story page 1, a right-hand page; the cover is 0).
    public var position: Int
    /// 1 for single pages, 2 for spreads (positions `position` and `position + 1`).
    public var span: Int
    /// A spread that starts on an odd (right-hand) position, i.e. split across two sheets.
    public var isSplit: Bool
    public init(id: PageID, position: Int, span: Int, isSplit: Bool) {
        self.id = id
        self.position = position
        self.span = span
        self.isSplit = isSplit
    }
}

/// One row of the overview: what sits on the left and right of an opening. Opening 0 is the
/// cover alone; opening 1 has only a right page (story page 1); later openings pair
/// positions (2k, 2k+1). A spread fills both sides with the same page ID. A split spread
/// appears on the right of one opening and the left of the next.
public struct Opening: Hashable, Sendable {
    public var left: PageID?
    public var right: PageID?
    public var isCover: Bool
    public init(left: PageID?, right: PageID?, isCover: Bool = false) {
        self.left = left
        self.right = right
        self.isCover = isCover
    }
}

public struct SequenceLayout: Hashable, Sendable {
    public var pages: [PagePosition]
    public var openings: [Opening]
    public var hasSplitSpread: Bool { pages.contains { $0.isSplit } }
    public func position(of id: PageID) -> PagePosition? { pages.first { $0.id == id } }
    public init(pages: [PagePosition], openings: [Opening]) {
        self.pages = pages
        self.openings = openings
    }
}

/// Maps `Book.pageOrder` to physical positions (A §8.1). Pure; no AppKit.
public enum PageSequencer {
    /// Lays out `order` (story pages only) after a cover with ID `cover`.
    public static func layout(_ order: [SequenceEntry], cover: PageID) -> SequenceLayout {
        var pages: [PagePosition] = []
        var occupant: [Int: PageID] = [:]
        var position = 1
        for entry in order {
            let span = entry.isSpread ? 2 : 1
            pages.append(PagePosition(id: entry.id, position: position, span: span,
                                      isSplit: entry.isSpread && position % 2 == 1))
            for p in position..<(position + span) { occupant[p] = entry.id }
            position += span
        }
        var openings = [Opening(left: nil, right: cover, isCover: true)]
        if position > 1 {
            openings.append(Opening(left: nil, right: occupant[1]))
            var left = 2
            while left < position {
                openings.append(Opening(left: occupant[left], right: occupant[left + 1]))
                left += 2
            }
        }
        return SequenceLayout(pages: pages, openings: openings)
    }

    /// Indices at which to insert blank single pages so no spread is split. The indices are
    /// into the order *as it grows*: apply them in ascending order with
    /// `order.insert(blank, at: i)`. Empty when nothing is split. Strategy: for each split
    /// spread, insert one blank immediately before it.
    public static func blankInsertions(for order: [SequenceEntry]) -> [Int] {
        var insertions: [Int] = []
        var position = 1
        var grownCount = 0
        for entry in order {
            if entry.isSpread && position % 2 == 1 {
                insertions.append(grownCount)
                grownCount += 1
                position += 1
            }
            grownCount += 1
            position += entry.isSpread ? 2 : 1
        }
        return insertions
    }
}
