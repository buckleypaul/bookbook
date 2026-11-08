import BBModel

/// Which page number is drawn on which physical position (A §8.1, PD §8.2). Pure.
public enum PageNumbering {
    /// The number text to draw for each physical position, keyed by position, for every
    /// position that shows one. Empty when `style.enabled` is false. Position 0 (cover) never
    /// shows one. Number = `style.startNumber + position - 1`; skipped when the page is in
    /// `style.skippedPages`, or `style.skipFrontMatter` and its template's `pageRole` is
    /// front matter. A spread shows a number on each of its two positions.
    public static func numbers(layout: SequenceLayout, style: PageNumberStyle,
                               pageRoles: [PageID: PageRole]) -> [Int: String] {
        guard style.enabled else { return [:] }
        var result: [Int: String] = [:]
        for page in layout.pages {
            if style.skippedPages.contains(page.id) { continue }
            if style.skipFrontMatter, pageRoles[page.id]?.isFrontMatter == true { continue }
            for position in page.position..<(page.position + page.span) where position >= 1 {
                result[position] = String(style.startNumber + position - 1)
            }
        }
        return result
    }

    /// The marks to pass in `RenderOptions.pageNumbers` for one page.
    public static func marks(for page: PageID, layout: SequenceLayout,
                             numbers: [Int: String]) -> [PageNumberMark] {
        guard let entry = layout.position(of: page) else { return [] }
        return (entry.position..<(entry.position + entry.span)).compactMap { position in
            guard let text = numbers[position] else { return nil }
            return PageNumberMark(text: text, half: position - entry.position, isLeftHand: position % 2 == 0)
        }
    }
}
