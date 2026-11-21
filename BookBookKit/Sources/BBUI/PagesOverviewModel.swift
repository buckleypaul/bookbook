import BBLayout
import BBModel
import BBStore
import Foundation

// MARK: - Overview rows (pure)

/// Which part of a page a slot of the overview shows.
public enum OverviewPart: Hashable, Sendable {
    /// A single page (or the cover).
    case single
    /// A spread's left half, on the right of an opening: the spread is split across sheets.
    case splitLeftHalf
    /// A spread's right half, on the left of the next opening (split).
    case splitRightHalf
}

/// One side of an opening: empty, or (part of) a page.
public struct OverviewSlot: Hashable, Sendable {
    public var pageID: PageID?
    public var part: OverviewPart
    /// The physical position (0 = cover), or nil for an empty slot.
    public var position: Int?

    public static let empty = OverviewSlot(pageID: nil, part: .single, position: nil)
}

/// One row of the spread overview (PD §8.5): the cover alone, then page 1 on the right, then
/// facing pairs. A spread that fills both sides of its opening is `spread`.
public struct OverviewRow: Hashable, Sendable, Identifiable {
    public var id: Int
    public var isCover: Bool
    public var left: OverviewSlot
    public var right: OverviewSlot
    /// Set when one spread page fills both sides.
    public var spread: PageID?
}

/// Pure helpers behind the Pages overview: rows, drag-and-drop orders, insertion points and
/// template choices. No views, no document.
public enum PagesOverviewModel {
    /// The sequencer's entries for the book's story pages (a page is a spread when its
    /// template is `.spread`).
    public static func entries(_ content: BookContent) -> [SequenceEntry] {
        PageSequencer.entries(for: content)
    }

    public static func layout(_ content: BookContent) -> SequenceLayout {
        PageSequencer.layout(for: content)
    }

    /// The overview's rows from `SequenceLayout.openings`.
    public static func rows(_ content: BookContent) -> [OverviewRow] {
        rows(layout(content))
    }

    public static func rows(_ layout: SequenceLayout) -> [OverviewRow] {
        let spans = Dictionary(layout.pages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return layout.openings.enumerated().map { index, opening in
            if opening.isCover {
                return OverviewRow(id: index, isCover: true, left: .empty,
                                   right: OverviewSlot(pageID: opening.right, part: .single, position: 0))
            }
            // Opening 1 holds position 1 on the right; opening k ≥ 2 holds (2k-2, 2k-1).
            let rightPosition = index == 1 ? 1 : 2 * index - 1
            let leftPosition = index == 1 ? nil : 2 * index - 2
            if let left = opening.left, left == opening.right {
                return OverviewRow(id: index, isCover: false,
                                   left: OverviewSlot(pageID: left, part: .single, position: leftPosition),
                                   right: OverviewSlot(pageID: left, part: .single, position: rightPosition),
                                   spread: left)
            }
            func slot(_ id: PageID?, position: Int?, isLeft: Bool) -> OverviewSlot {
                guard let id, let position else { return .empty }
                let isSpread = (spans[id]?.span ?? 1) == 2
                let part: OverviewPart = isSpread ? (isLeft ? .splitRightHalf : .splitLeftHalf) : .single
                return OverviewSlot(pageID: id, part: part, position: position)
            }
            return OverviewRow(id: index, isCover: false,
                               left: slot(opening.left, position: leftPosition, isLeft: true),
                               right: slot(opening.right, position: rightPosition, isLeft: false))
        }
    }

    /// The page-order index for a page inserted after `selection`: right after a story page,
    /// first after the cover, and at the end with no selection.
    public static func insertionIndex(after selection: PageID?, in content: BookContent) -> Int {
        let order = content.book.pageOrder
        if selection == content.book.coverPageID { return 0 }
        guard let selection, let index = order.firstIndex(of: selection) else { return order.count }
        return index + 1
    }

    /// The order after dropping `moving` onto `target`: the moved page takes the target's
    /// place (after it when moving forward, before it when moving back). Nil when nothing
    /// would change or either page isn't in `order`.
    public static func order(moving: PageID, onto target: PageID, in order: [PageID]) -> [PageID]? {
        guard moving != target, let from = order.firstIndex(of: moving), let to = order.firstIndex(of: target)
        else { return nil }
        var result = order
        result.remove(at: from)
        // After removal, the target's index shifts down by one when it was after `from`.
        let targetIndex = result.firstIndex(of: target)!
        result.insert(moving, at: to > from ? targetIndex + 1 : targetIndex)
        return result == order ? nil : result
    }

    /// The order after dropping `moving` past the last page.
    public static func order(movingToEnd moving: PageID, in order: [PageID]) -> [PageID]? {
        guard let from = order.firstIndex(of: moving), from != order.count - 1 else { return nil }
        var result = order
        result.remove(at: from)
        result.append(moving)
        return result
    }

    /// Templates offered for a page: `.cover` templates for the cover, `.single`/`.spread`
    /// otherwise. The bundled presets first (the book's own copy when it has one), in preset
    /// order, then the book's other templates by name.
    public static func templateChoices(forCover: Bool, in content: BookContent,
                                       presets: [Template]) -> [Template] {
        let pageKind: PageKind = forCover ? .cover : .story
        func fits(_ t: Template) -> Bool { pageKind.accepts(t.kind) }
        var seen = Set<TemplateID>()
        var result: [Template] = []
        for preset in presets where fits(preset) && seen.insert(preset.id).inserted {
            result.append(content.templates[preset.id] ?? preset)
        }
        let others = content.templates.values.filter { fits($0) && !seen.contains($0.id) }
            .sorted { ($0.name, $0.id.rawValue.uuidString) < ($1.name, $1.id.rawValue.uuidString) }
        return result + others
    }

    /// Label for a physical position in the overview ("Cover", "1", "2"…), using the page
    /// numbers' start number.
    public static func positionLabel(_ position: Int?, startNumber: Int) -> String? {
        guard let position else { return nil }
        return position == 0 ? "Cover" : String(startNumber + position - 1)
    }

    /// The overview's keyboard selection: the page `step` places before (negative) or after
    /// `selection` in reading order (the cover, then the story pages), stopping at either end.
    /// With no (or an unknown) selection, the first page. Nil for a book with no pages.
    public static func page(_ step: Int, from selection: PageID?, in content: BookContent) -> PageID? {
        var order = content.book.pageOrder
        if content.pages[content.book.coverPageID] != nil { order.insert(content.book.coverPageID, at: 0) }
        guard !order.isEmpty else { return nil }
        guard let selection, let index = order.firstIndex(of: selection) else { return order.first }
        return order[min(max(index + step, 0), order.count - 1)]
    }
}
