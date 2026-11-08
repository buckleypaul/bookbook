import BBModel
import Foundation

// Phase 2 contract (main thread). Implementations live in the Store lane's files.

public enum StoreError: Error, Hashable, Sendable {
    case notFound(String)
    case corrupt(String)
    case io(String)
    /// The book was written by a newer BookBook.
    case schemaTooNew(Int)
    case keychain(Int32)
}

/// Which entities changed since the last save. Accumulates until a save completes.
public struct DirtySet: Hashable, Sendable {
    public var book: Bool
    public var style: Bool
    public var templates: Set<TemplateID>
    public var pages: Set<PageID>
    public var sessions: Set<SessionID>
    public var deletedPages: Set<PageID>

    public init(book: Bool = false, style: Bool = false, templates: Set<TemplateID> = [], pages: Set<PageID> = [],
                sessions: Set<SessionID> = [], deletedPages: Set<PageID> = []) {
        self.book = book
        self.style = style
        self.templates = templates
        self.pages = pages
        self.sessions = sessions
        self.deletedPages = deletedPages
    }

    public var isEmpty: Bool {
        !book && !style && templates.isEmpty && pages.isEmpty && sessions.isEmpty && deletedPages.isEmpty
    }

    public mutating func formUnion(_ other: DirtySet) {
        book = book || other.book
        style = style || other.style
        templates.formUnion(other.templates)
        pages.formUnion(other.pages)
        sessions.formUnion(other.sessions)
        // A page deleted then re-added (undo) is written, not deleted, and vice versa.
        deletedPages.subtract(other.pages)
        pages.subtract(other.deletedPages)
        deletedPages.formUnion(other.deletedPages)
    }

    /// Everything in `content` (used when creating a book).
    public static func all(_ content: BookContent) -> DirtySet {
        DirtySet(book: true, style: true, templates: Set(content.templates.keys), pages: Set(content.pages.keys),
                 sessions: Set(content.sessions.keys))
    }
}

/// A book in the library folder.
public struct LibraryEntry: Hashable, Sendable, Identifiable {
    public var id: BookID
    public var title: String
    public var url: URL
    public var modifiedAt: Date

    public init(id: BookID, title: String, url: URL, modifiedAt: Date) {
        self.id = id
        self.title = title
        self.url = url
        self.modifiedAt = modifiedAt
    }
}
