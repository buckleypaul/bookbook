import Foundation

/// Text boxes with role `.title` / `.author` show the book's title and author (PD §8.7), not
/// the page's stored text.
public enum CoverText {
    /// True for a role whose text comes from the book, not the page (not editable in place).
    public static func isBound(_ role: BoxRole?) -> Bool {
        role == .title || role == .author
    }

    public static func boundText(for role: BoxRole?, book: Book) -> RichText? {
        switch role {
        case .title: return RichText(plain: book.title)
        case .author: return RichText(plain: book.author)
        default: return nil
        }
    }
}

extension BookContent {
    /// The text a text box on `page` shows: the book's title or author for a bound role
    /// (`CoverText`), else the page's own text.
    public func displayedText(page: Page, box: Box) -> RichText? {
        CoverText.boundText(for: box.role, book: book) ?? page.text[box.id]
    }
}
