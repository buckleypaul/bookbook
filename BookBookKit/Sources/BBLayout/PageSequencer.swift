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
        fatalError("Phase 5 lane L1")
    }

    /// Indices at which to insert blank single pages so no spread is split. The indices are
    /// into the order *as it grows*: apply them in ascending order with
    /// `order.insert(blank, at: i)`. Empty when nothing is split. Strategy: for each split
    /// spread, insert one blank immediately before it.
    public static func blankInsertions(for order: [SequenceEntry]) -> [Int] {
        fatalError("Phase 5 lane L1")
    }
}
