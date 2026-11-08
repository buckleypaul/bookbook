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
        var out: [PageID] = []
        if let cover = pages[book.coverPageID], cover.templateID == templateID { out.append(cover.id) }
        for id in book.pageOrder where pages[id]?.templateID == templateID && id != book.coverPageID { out.append(id) }
        return out
    }

    /// The version placed in a box, if any.
    public func placedVersion(page pageID: PageID, box boxID: BoxID) -> Version? {
        guard let slot = pages[pageID]?.images[boxID], let placement = slot.placement else { return nil }
        return sessions[slot.sessionID]?.version(placement.versionID)
    }

    /// A box's aspect (width / height) as rendered: its frame on the trim, with each edge in
    /// `bleedEdges` pushed out by the bleed when bleed is on (matches
    /// `BBLayout.PageGeometry.renderRect`, the authority). Spread templates use the doubled
    /// width. Phase 7 lane: add bleed and spread width.
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

/// Out-of-date flags on a placed image (A §4.4, PD §8.5). Asset changed (Phase 10) and
/// consistency warning (Phase 12) are reserved and never set in Phase 7.
public struct ImageFlags: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let styleChanged = ImageFlags(rawValue: 1 << 0)
    public static let assetChanged = ImageFlags(rawValue: 1 << 1)
    public static let layoutChanged = ImageFlags(rawValue: 1 << 2)
    public static let consistencyWarning = ImageFlags(rawValue: 1 << 3)
}

extension BookContent {
    /// Flags for one image box (A §4.4, Phase 7 rules):
    /// - style changed: the placed version has provenance and
    ///   `max(provenance.styleRevision, acknowledged.styleRevision) < style.visualRevision`;
    ///   imported versions (no provenance) never get it;
    /// - layout changed: `abs(log(boxAspect(box) / (acknowledged.boxAspect ?? placement.boxAspectWhenPlaced))) > 0.05`.
    /// Empty for an empty box. Phase 7 lane: implement.
    public func imageFlags(page pageID: PageID, box boxID: BoxID) -> ImageFlags { [] }

    /// Union of `imageFlags(page:box:)` over the page's image boxes.
    public func imageFlags(of page: Page) -> ImageFlags {
        guard let template = template(for: page) else { return [] }
        return template.imageBoxes.reduce(into: ImageFlags()) { $0.formUnion(imageFlags(page: page.id, box: $1.id)) }
    }
}
