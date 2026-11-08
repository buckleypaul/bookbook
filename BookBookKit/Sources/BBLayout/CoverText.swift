import BBModel

/// Text boxes with role `.title` / `.author` show the book's title and author (PD §8.7), not
/// the page's stored text.
enum CoverText {
    static func boundText(for role: BoxRole?, book: Book) -> RichText? {
        switch role {
        case .title: return RichText(plain: book.title)
        case .author: return RichText(plain: book.author)
        default: return nil
        }
    }
}
