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

    /// Every file and folder in the package: relative path → (modification date, contents).
    private func tree(_ url: URL) throws -> [String: (Date?, Data?)] {
        let base = url.resolvingSymlinksInPath().path(percentEncoded: false)
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
        var out: [String: (Date?, Data?)] = [:]
        let walker = try #require(FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys))
        for case let file as URL in walker {
            let values = try file.resourceValues(forKeys: Set(keys))
            let path = String(file.resolvingSymlinksInPath().path(percentEncoded: false).dropFirst(base.count))
            out[path] = (values.contentModificationDate, values.isDirectory == true ? nil : try Data(contentsOf: file))
        }
        return out
    }

    /// A closed book whose lock a live process elsewhere holds: a background delivery and a
    /// snapshot leave the package exactly as it was (the uncommitted journal, an old orphan image
    /// and the lock all stay; nothing is written) and the delivery is reported as not saved.
    @Test func closedBookLockedByAnotherProcess_deliveryAndSnapshotDontTouchThePackage() async throws {
        let s = try await setup()
        defer { try? FileManager.default.removeItem(at: s.root) }
        let fm = FileManager.default
        // A lock from another host is always live.
        let owner = LockOwner(pid: 4242, host: "another-mac.example", acquiredAt: Fixtures.date)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(owner).write(to: s.entry.url.appending(path: ".lock"))
        // The other process's in-flight (uncommitted) transaction: an open by us would discard it.
        let staged = s.entry.url.appending(path: ".journal/tx-inflight/staged", directoryHint: .isDirectory)
        try fm.createDirectory(at: staged, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: staged.appending(path: "book.json"))
        // An unreferenced image two days old: an open by us would sweep it.
        let orphan = BookStore(packageURL: s.entry.url)
            .imageURL(for: ImageRef(sha256: String(repeating: "ab", count: 32), contentType: "public.png"))
        try Data([9, 9, 9]).write(to: orphan)
        try fm.setAttributes([.modificationDate: Fixtures.date.addingTimeInterval(-2 * 86_400)],
                             ofItemAtPath: orphan.path(percentEncoded: false))
        let before = try tree(s.entry.url)

        var problems: [(MessageID, String)] = []
        s.books.onDeliveryProblem = { problems.append(($0, $1)) }
        await s.books.deliver(s.delivery, now: { Fixtures.date })
        let snapshot = await s.books.content(for: s.entry.id)

        let after = try tree(s.entry.url)
        #expect(Set(after.keys) == Set(before.keys))
        for (path, value) in before {
            #expect(after[path]?.0 == value.0, "\(path) changed")
            #expect(after[path]?.1 == value.1, "\(path) changed")
        }
        #expect(problems.count == 1)
        #expect(problems.first?.0 == s.delivery.item.messageID)
        #expect(problems.first?.1.contains("another-mac.example") == true)
        // The snapshot still reads the book (read-only), without the undelivered version.
        #expect(snapshot?.book.id == s.entry.id)
        #expect(snapshot?.sessions[s.sessionID]?.versions.isEmpty == true)
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
