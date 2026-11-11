import BBModel

/// The page-number marks for every page of a book (A §8.1, PD §8.2): `PageSequencer` positions
/// from `book.pageOrder` (a page is a spread when its template is `.spread`), numbered by
/// `PageNumbering` with each page's template `pageRole`. Pure. One snapshot per call, so build
/// it once per export or draw pass.
public struct PageNumberMarks: Sendable {
    public let layout: SequenceLayout
    public let numbers: [Int: String]

    public init(content: BookContent) {
        layout = PageSequencer.layout(for: content)
        let roles = content.pages.compactMapValues { content.template(for: $0)?.pageRole }
        numbers = PageNumbering.numbers(layout: layout, style: content.style.pageNumbers, pageRoles: roles)
    }

    /// The marks for one page (none for the cover or a page not in the reading order).
    public func marks(for page: PageID) -> [PageNumberMark] {
        PageNumbering.marks(for: page, layout: layout, numbers: numbers)
    }
}
