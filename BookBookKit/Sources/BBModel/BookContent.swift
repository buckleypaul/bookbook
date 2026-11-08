import Foundation

/// The whole in-memory book: a value tree (A §1.2, §6.1 `BookState`). `BookStore` loads and
/// saves it; `BookDocument` holds it; queue context is assembled from a snapshot of it.
public struct BookContent: Hashable, Sendable {
    public var book: Book
    public var style: StyleGuide
    public var templates: [TemplateID: Template]
    public var pages: [PageID: Page]
    public var sessions: [SessionID: Session]

    public init(book: Book, style: StyleGuide, templates: [TemplateID: Template],
                pages: [PageID: Page], sessions: [SessionID: Session]) {
        self.book = book
        self.style = style
        self.templates = templates
        self.pages = pages
        self.sessions = sessions
    }

    // MARK: Derived queries (A §4.4)

    /// Story pages in reading order (excludes the cover).
    public var storyPages: [Page] { book.pageOrder.compactMap { pages[$0] } }

    public var coverPage: Page? { pages[book.coverPageID] }

    public func template(for page: Page) -> Template? { templates[page.templateID] }

    /// Where a template is used (Phase 6): the cover first if it uses it, then story pages in
    /// reading order.
    public func pages(using templateID: TemplateID) -> [PageID] {
        fatalError("Phase 6 lane L1")
    }

    /// The version placed in a box, if any.
    public func placedVersion(page pageID: PageID, box boxID: BoxID) -> Version? {
        guard let slot = pages[pageID]?.images[boxID], let placement = slot.placement else { return nil }
        return sessions[slot.sessionID]?.version(placement.versionID)
    }

    /// A box's aspect (width / height) on the trim, ignoring bleed. Bleed comes in Phase 7;
    /// `BBLayout.PageGeometry` is the authority for render rects.
    public func boxAspect(_ box: Box) -> Double {
        let trim = style.pageSetup.trimSize
        return (box.frame.width * trim.width) / (box.frame.height * trim.height)
    }

    /// Page status (A §4.4).
    public func status(of page: Page) -> PageStatus {
        if page.isDone { return .done }
        let hasText = page.text.values.contains { !$0.isEmpty }
        let hasImage = page.images.values.contains { $0.placement != nil }
        return (hasText || hasImage) ? .inProgress : .empty
    }

    // MARK: Factory

    /// A new book with one cover page and `storyPageCount` story pages (Phase 2: 1, decided
    /// 2026-11-08). Every image box gets an empty session.
    public static func makeNew(title: String, author: String = "", storyTemplate: Template,
                               coverTemplate: Template, storyPageCount: Int = 1, now: Date) -> BookContent {
        var pages: [PageID: Page] = [:]
        var sessions: [SessionID: Session] = [:]
        let cover = makePage(kind: .cover, template: coverTemplate, sessions: &sessions)
        pages[cover.id] = cover
        var order: [PageID] = []
        for _ in 0..<max(0, storyPageCount) {
            let page = makePage(kind: .story, template: storyTemplate, sessions: &sessions)
            pages[page.id] = page
            order.append(page.id)
        }
        let book = Book(title: title, author: author, createdAt: now, modifiedAt: now,
                        pageOrder: order, coverPageID: cover.id)
        return BookContent(book: book, style: StyleGuide(),
                           templates: Dictionary([storyTemplate, coverTemplate].map { ($0.id, $0) },
                                                 uniquingKeysWith: { first, _ in first }),
                           pages: pages, sessions: sessions)
    }

    /// A page using `template`, with an empty session per image box (added to `sessions`).
    public static func makePage(kind: PageKind, template: Template, sessions: inout [SessionID: Session]) -> Page {
        var page = Page(kind: kind, templateID: template.id)
        for box in template.imageBoxes {
            let session = Session(owner: .pageBox(page.id, box.id))
            sessions[session.id] = session
            page.images[box.id] = ImageSlot(sessionID: session.id)
        }
        return page
    }
}

public enum PageStatus: String, Sendable {
    case empty, inProgress, done
}
