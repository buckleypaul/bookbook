import Foundation

/// The whole in-memory book: a value tree (A §1.2, §6.1 `BookState`). `BookStore` loads and
/// saves it; `BookDocument` holds it; queue context is assembled from a snapshot of it.
public struct BookContent: Hashable, Sendable {
    public var book: Book
    public var style: StyleGuide
    public var templates: [TemplateID: Template]
    public var pages: [PageID: Page]
    public var sessions: [SessionID: Session]
    /// Phase 10: `assets/<id>.json`.
    public var assets: [AssetID: Asset]

    public init(book: Book, style: StyleGuide, templates: [TemplateID: Template],
                pages: [PageID: Page], sessions: [SessionID: Session], assets: [AssetID: Asset] = [:]) {
        self.assets = assets
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

    /// The cover's ID, then the story pages' in reading order (the cover is never repeated).
    public var pageIDsCoverFirst: [PageID] {
        [book.coverPageID] + book.pageOrder.filter { $0 != book.coverPageID }
    }

    public func template(for page: Page) -> Template? { templates[page.templateID] }

    /// Where a template is used (Phase 6): the cover first if it uses it, then story pages in
    /// reading order.
    public func pages(using templateID: TemplateID) -> [PageID] {
        pageIDsCoverFirst.filter { pages[$0]?.templateID == templateID }
    }

    /// The version placed in a box, if any.
    public func placedVersion(page pageID: PageID, box boxID: BoxID) -> Version? {
        guard let slot = pages[pageID]?.images[boxID], let placement = slot.placement else { return nil }
        return sessions[slot.sessionID]?.version(placement.versionID)
    }

    /// A box's aspect (width / height) as rendered: its frame on the trim, with each edge in
    /// `bleedEdges` pushed out by the bleed when bleed is on (matches
    /// `BBLayout.PageGeometry.renderRect`, the authority). A spread template uses the doubled
    /// width.
    public func boxAspect(_ box: Box, in template: Template) -> Double {
        boxAspect(box, spread: template.kind == .spread)
    }

    private func boxAspect(_ box: Box, spread: Bool) -> Double {
        let setup = style.pageSetup
        let trimW = setup.trimSize.width * (spread ? 2 : 1)
        let trimH = setup.trimSize.height
        var minX = box.frame.x * trimW
        var minY = box.frame.y * trimH
        var maxX = box.frame.maxX * trimW
        var maxY = box.frame.maxY * trimH
        let bleed = setup.bleedEnabled ? max(0, setup.bleedAmount) : 0
        if bleed > 0 {
            // Same fold rule as `PageGeometry.pushedBleedEdges`: no bleed on an edge at a spread's fold.
            var edges = box.bleedEdges
            if spread {
                let fold = trimW / 2
                if abs(minX - fold) <= 0.5 { edges.remove(.leading) }
                if abs(maxX - fold) <= 0.5 { edges.remove(.trailing) }
            }
            if edges.contains(.top) { minY -= bleed }
            if edges.contains(.leading) { minX -= bleed }
            if edges.contains(.bottom) { maxY += bleed }
            if edges.contains(.trailing) { maxX += bleed }
        }
        let w = max(0, maxX - minX), h = max(0, maxY - minY)
        return h > 0 ? w / h : 0
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

/// Out-of-date flags on a placed image (A §4.4, PD §8.5). Asset changed is set from Phase 10;
/// consistency warning (Phase 12) is set while the placed version's latest check shows a warning.
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
    ///   `provenance.styleRevision != style.visualRevision` and `acknowledged.styleRevision != style.visualRevision`
    ///   (revisions are never reused, so "newer" and "different" agree except after an undo);
    ///   imported versions (no provenance) never get it;
    /// - asset changed (Phase 10): for any `(asset, rec)` in the placed version's
    ///   `provenance.assetRevisions` whose asset still exists,
    ///   `max(rec, acknowledged.assetRevisions[asset] ?? 0) < assets[asset].revision`;
    /// - consistency warning (Phase 12): the placed version's `consistency?.showsWarning` is true;
    /// - layout changed: `abs(log(boxAspect(box, in: template) / (acknowledged.boxAspect ?? placement.boxAspectWhenPlaced))) > 0.05`.
    /// Empty for an empty box.
    public func imageFlags(page pageID: PageID, box boxID: BoxID) -> ImageFlags {
        guard let page = pages[pageID], let template = template(for: page), let box = template.box(boxID),
              let slot = page.images[boxID], let placement = slot.placement else { return [] }
        var flags: ImageFlags = []
        let version = sessions[slot.sessionID]?.version(placement.versionID)
        if let provenance = version?.provenance,
           provenance.styleRevision != style.visualRevision,
           slot.acknowledged.styleRevision != style.visualRevision {
            flags.insert(.styleChanged)
        }
        if let revisions = version?.provenance?.assetRevisions,
           revisions.contains(where: { id, rec in
               guard let asset = assets[id] else { return false }
               return max(rec, slot.acknowledged.assetRevisions[id] ?? 0) < asset.revision
           }) {
            flags.insert(.assetChanged)
        }
        if version?.consistency?.showsWarning == true {
            flags.insert(.consistencyWarning)
        }
        let baseline = slot.acknowledged.boxAspect ?? placement.boxAspectWhenPlaced
        let current = boxAspect(box, in: template)
        if baseline > 0, current > 0, abs(log(current / baseline)) > 0.05 {
            flags.insert(.layoutChanged)
        }
        return flags
    }

    /// Union of `imageFlags(page:box:)` over the page's image boxes.
    public func imageFlags(of page: Page) -> ImageFlags {
        guard let template = template(for: page) else { return [] }
        return template.imageBoxes.reduce(into: ImageFlags()) { $0.formUnion(imageFlags(page: page.id, box: $1.id)) }
    }
}
