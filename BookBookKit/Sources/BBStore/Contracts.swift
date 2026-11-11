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
    /// Phase 3: another live process holds the book's `.lock`.
    case locked(LockOwner)
    /// Phase 3: the store was opened read-only; writes are refused.
    case readOnly
}

// MARK: Phase 3 contract (main thread)

/// Contents of a book's `.lock` file (A §5.3).
public struct LockOwner: Codable, Hashable, Sendable {
    public var pid: Int32
    /// The host name, for display. Same-machine checks use `hostID` when both sides have one.
    public var host: String
    public var acquiredAt: Date
    /// Phase 16b (#99b): the Mac's hardware UUID (`gethostuuid(2)`). Optional: locks written
    /// before Phase 16b don't have it (synthesized `Codable`: decoded with `decodeIfPresent`, omitted when nil).
    public var hostID: String?

    public init(pid: Int32, host: String, acquiredAt: Date, hostID: String? = nil) {
        self.pid = pid
        self.host = host
        self.acquiredAt = acquiredAt
        self.hostID = hostID
    }
}

public extension LockOwner {
    /// This process on this Mac, as `.lock` would record it now.
    static var current: LockOwner { BookLock.currentOwner() }

    /// Whether `self` and `other` name the same Mac: by `hostID` when both have one, else by
    /// host name (locks written before Phase 16b).
    func isOnSameMachine(as other: LockOwner) -> Bool {
        BookLock.sameMachine(self, other)
    }
}

public enum LockAcquisition: Hashable, Sendable {
    /// This store now holds the lock (fresh, re-entrant from this process, or a stale lock taken over).
    case acquired
    /// Another live process holds it. The caller may offer to open read-only (`BookStore.setReadOnly()`).
    case heldByOther(LockOwner)
}

/// Which entities changed since the last save. Accumulates until a save completes.
public struct DirtySet: Hashable, Sendable {
    public var book: Bool
    public var style: Bool
    public var templates: Set<TemplateID>
    public var pages: Set<PageID>
    public var sessions: Set<SessionID>
    public var deletedPages: Set<PageID>
    /// Phase 6: templates removed from the book; `templates/<id>.json` is deleted in the same transaction.
    public var deletedTemplates: Set<TemplateID>
    /// Phase 10: `assets/<id>.json` to write / delete (same delete-then-undo rules as templates).
    public var assets: Set<AssetID> = []
    public var deletedAssets: Set<AssetID> = []

    public init(book: Bool = false, style: Bool = false, templates: Set<TemplateID> = [], pages: Set<PageID> = [],
                sessions: Set<SessionID> = [], deletedPages: Set<PageID> = [],
                deletedTemplates: Set<TemplateID> = [], assets: Set<AssetID> = [], deletedAssets: Set<AssetID> = []) {
        self.book = book
        self.style = style
        self.templates = templates
        self.pages = pages
        self.sessions = sessions
        self.deletedPages = deletedPages
        self.deletedTemplates = deletedTemplates
        self.assets = assets
        self.deletedAssets = deletedAssets
    }

    public var isEmpty: Bool {
        !book && !style && templates.isEmpty && pages.isEmpty && sessions.isEmpty && deletedPages.isEmpty
            && deletedTemplates.isEmpty && assets.isEmpty && deletedAssets.isEmpty
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
        // Likewise for templates (delete, then undo re-inserts it).
        deletedTemplates.subtract(other.templates)
        templates.subtract(other.deletedTemplates)
        deletedTemplates.formUnion(other.deletedTemplates)
        deletedAssets.subtract(other.assets)
        assets.subtract(other.deletedAssets)
        assets.formUnion(other.assets)
        deletedAssets.formUnion(other.deletedAssets)
    }

    /// Everything in `content` (used when creating a book).
    public static func all(_ content: BookContent) -> DirtySet {
        DirtySet(book: true, style: true, templates: Set(content.templates.keys), pages: Set(content.pages.keys),
                 sessions: Set(content.sessions.keys), assets: Set(content.assets.keys))
    }
}

/// A book in the library folder. Codable for the cached library index (Phase 3).
public struct LibraryEntry: Codable, Hashable, Sendable, Identifiable {
    public var id: BookID
    public var title: String
    public var url: URL
    public var modifiedAt: Date
    /// `<package>/thumbnail.png` when it exists (Phase 3).
    public var thumbnailURL: URL?

    public init(id: BookID, title: String, url: URL, modifiedAt: Date, thumbnailURL: URL? = nil) {
        self.id = id
        self.title = title
        self.url = url
        self.modifiedAt = modifiedAt
        self.thumbnailURL = thumbnailURL
    }
}
