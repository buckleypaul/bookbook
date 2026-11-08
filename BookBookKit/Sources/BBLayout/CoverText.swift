import BBModel

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
