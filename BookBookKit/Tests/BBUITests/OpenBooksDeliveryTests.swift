import BBAI
import BBAICore
import BBModel
import BBStore
import Foundation
import Testing
@testable import BBUI

/// Deliveries against real packages on disk, racing open and close (A §6.4).
@MainActor
struct OpenBooksDeliveryTests {
    private struct Setup {
        var root: URL
        var books: OpenBooks
        var entry: LibraryEntry
        var delivery: GenerationDelivery
        var sessionID: SessionID
        var page: PageID
        var box: BoxID
    }

    /// A new library book whose first image box has one pending message, saved to disk.
    private func setup() async throws -> Setup {
        let root = FileManager.default.temporaryDirectory.appending(path: "bbui-openbooks-\(UUID().uuidString)")
        let library = Library(root: root)
        let entry = try library.createBook(title: "Race", now: Fixtures.date)
        let store = BookStore(packageURL: entry.url)
        var content = try await store.load()
        let page = try #require(content.book.pageOrder.first)
        let box = try #require(content.pages[page]?.images.keys.first)
        let (message, item) = BookMutations.makeGeneration(prompt: "a fox", refines: nil, defaults: GenerationDefaults(),
                                                           bookID: content.book.id, page: page, box: box,
                                                           now: Fixtures.date)
        let dirty = BookMutations.appendPendingMessage(message, page: page, box: box, to: &content)
        try await store.save(content, dirty: dirty)
        let sessionID = try #require(content.pages[page]?.images[box]?.sessionID)
        let delivery = GenerationDelivery(item: item, outcome: .success(result: Fixtures.result(),
                                                                         provenance: Fixtures.provenance()))
        let books = OpenBooks(library: library)
        books.remember([entry])
        return Setup(root: root, books: books, entry: entry, delivery: delivery, sessionID: sessionID, page: page, box: box)
    }

    private func onDisk(_ s: Setup) async throws -> BookContent {
        try await BookStore(packageURL: s.entry.url).load()
    }

    private func expectDelivered(_ content: BookContent, _ s: Setup) {
        let session = content.sessions[s.sessionID]
        #expect(session?.versions.count == 1)
        #expect(session?.messages.first?.queueItemID == nil)
        #expect(session?.messages.first?.producedVersion == session?.versions.first?.id)
        #expect(content.pages[s.page]?.images[s.box]?.placement?.versionID == session?.versions.first?.id)
    }

    @Test func closedBook_deliveryIsWrittenToDisk_imageFirst() async throws {
        let s = try await setup()
        defer { try? FileManager.default.removeItem(at: s.root) }
        await s.books.deliver(s.delivery, now: { Fixtures.date })
        let content = try await onDisk(s)
        expectDelivered(content, s)
        let ref = try #require(content.sessions[s.sessionID]?.versions.first?.image)
        #expect(FileManager.default.fileExists(atPath: BookStore(packageURL: s.entry.url).imageURL(for: ref).path))
    }

    @Test func openRacingAClosedBookDelivery_seesTheVersion() async throws {
        let s = try await setup()
        defer { try? FileManager.default.removeItem(at: s.root) }
        let books = s.books, delivery = s.delivery
        let delivering = Task { await books.deliver(delivery, now: { Fixtures.date }) }
        let document = try await books.open(s.entry.id)
        await delivering.value
        expectDelivered(document.content, s)
        await books.close(s.entry.id)
        expectDelivered(try await onDisk(s), s)
    }

    @Test func deliveryRacingClose_isNotLost() async throws {
        let s = try await setup()
        defer { try? FileManager.default.removeItem(at: s.root) }
        let books = s.books, delivery = s.delivery, id = s.entry.id
        _ = try await books.open(id)
        let closing = Task { await books.close(id) }
        let delivering = Task { await books.deliver(delivery, now: { Fixtures.date }) }
        await closing.value
        await delivering.value
        #expect(books.document(for: id) == nil)
        expectDelivered(try await onDisk(s), s)
    }

    @Test func deliveryToAnOpenBook_isSavedByTheNextClose() async throws {
        let s = try await setup()
        defer { try? FileManager.default.removeItem(at: s.root) }
        let document = try await s.books.open(s.entry.id)
        await s.books.deliver(s.delivery, now: { Fixtures.date })
        expectDelivered(document.content, s)
        await s.books.close(s.entry.id)
        expectDelivered(try await onDisk(s), s)
    }
}
