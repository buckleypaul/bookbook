import BBAI
import BBAICore
import BBModel
import BBStore
import Foundation
import Testing
@testable import BBUI

/// Ledger lines and delivery results for books that aren't open here (A §6.4, §7.10).
@MainActor
struct ClosedBookLedgerTests {
    private struct Setup {
        var h: Phase9Harness
        var entry: LibraryEntry
        var books: OpenBooks
        var writer: BookWriter
        var delivery: GenerationDelivery
        var sessionID: SessionID
    }

    /// A closed library book with one pending message on its first image box.
    private func setup() async throws -> Setup {
        let h = try Phase9Harness()
        let entry = try h.createBook()
        let store = BookStore(packageURL: entry.url)
        var content = try await store.load()
        let (page, box) = try Phase9Harness.firstImageBox(content)
        let (message, item) = Fixtures.generation("a fox", bookID: content.book.id, page: page, box: box)
        let dirty = BookMutations.appendPendingMessage(message, target: .pageBox(page, box), to: &content)
        try await store.save(content, dirty: dirty)
        var provenance = Fixtures.provenance()
        provenance.cost = CostRecordID()
        let delivery = GenerationDelivery(item: item, outcome: .success(result: Fixtures.result(), provenance: provenance),
                                          costRecordID: provenance.cost)
        let books = OpenBooks(library: Library(root: h.libraryRoot), defaults: h.defaults)
        books.remember([entry])
        let sessionID = try #require(content.pages[page]?.images[box]?.sessionID)
        return Setup(h: h, entry: entry, books: books, writer: BookWriter(openBooks: books, now: { Fixtures.date }),
                     delivery: delivery, sessionID: sessionID)
    }

    private func lockByAnotherProcess(_ url: URL) throws {
        let owner = LockOwner(pid: 4242, host: "another-mac.example", acquiredAt: Fixtures.date)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(owner).write(to: url.appending(path: ".lock"))
    }

    @Test func recordCost_appendsToAClosedBook() async throws {
        let s = try await setup()
        defer { s.h.tearDown() }
        let first = Phase9Harness.record(Decimal(string: "0.02")!, at: Fixtures.date)
        let second = Phase9Harness.record(Decimal(string: "0.05")!, basis: .estimate, at: Fixtures.date.addingTimeInterval(5))
        await s.writer.recordCost(first, in: s.entry.id)
        await s.writer.recordCost(second, in: s.entry.id)
        let records = try CostLedger(packageURL: s.entry.url).records(CostRecord.self)
        #expect(records == [first, second])
        #expect(!FileManager.default.fileExists(atPath: s.entry.url.appending(path: ".lock").path(percentEncoded: false)))

        let app = s.h.makeApp()
        await app.start()
        let summary = await app.ledgerSummary(for: s.entry.id)
        #expect(summary.total == Decimal(string: "0.07"))
        #expect(summary.recent.map(\.id) == [second.id, first.id])
        #expect(await app.costRecord(second.id, in: s.entry.id) == second)
        #expect(await app.costRecord(CostRecordID(), in: s.entry.id) == nil)
    }

    /// The ledger line is a single `O_APPEND` write: a book another process has open still
    /// gets it (the line must not be lost; the request may have been billed).
    @Test func recordCost_appendsWhileAnotherProcessHoldsTheLock() async throws {
        let s = try await setup()
        defer { s.h.tearDown() }
        try lockByAnotherProcess(s.entry.url)
        let record = Phase9Harness.record(Decimal(string: "0.02")!)
        await s.writer.recordCost(record, in: s.entry.id)
        #expect(try CostLedger(packageURL: s.entry.url).records(CostRecord.self) == [record])
    }

    @Test func recordCost_forAGoneBookIsDropped() async throws {
        let s = try await setup()
        defer { s.h.tearDown() }
        try FileManager.default.removeItem(at: s.entry.url)
        await s.writer.recordCost(Phase9Harness.record(1), in: s.entry.id)
        #expect(!FileManager.default.fileExists(atPath: s.entry.url.path(percentEncoded: false)))
    }

    @Test func deliver_closedBook_isDeliveredAndKeepsTheCostID() async throws {
        let s = try await setup()
        defer { s.h.tearDown() }
        #expect(await s.writer.deliver(s.delivery) == .delivered)
        let content = try await BookStore(packageURL: s.entry.url).load()
        let version = try #require(content.sessions[s.sessionID]?.versions.first)
        #expect(version.provenance?.cost == s.delivery.costRecordID)
        #expect(version.provenance?.cost != nil)
        #expect(FileManager.default.fileExists(atPath: BookStore(packageURL: s.entry.url).imageURL(for: version.image).path))
    }

    @Test func deliver_lockedByAnotherProcess_isUnavailableAndWritesNothing() async throws {
        let s = try await setup()
        defer { s.h.tearDown() }
        try lockByAnotherProcess(s.entry.url)
        let before = try Data(contentsOf: s.entry.url.appending(path: "sessions/\(s.sessionID.rawValue.uuidString).json"))
        #expect(await s.writer.deliver(s.delivery) == .bookUnavailable)
        let after = try Data(contentsOf: s.entry.url.appending(path: "sessions/\(s.sessionID.rawValue.uuidString).json"))
        #expect(before == after)

        // Once the other process lets go, the retried delivery lands.
        try FileManager.default.removeItem(at: s.entry.url.appending(path: ".lock"))
        var problems: [MessageID] = []
        var delivered: [MessageID] = []
        s.books.onDeliveryProblem = { id, _ in problems.append(id) }
        s.books.onDelivered = { delivered.append($0) }
        #expect(await s.writer.deliver(s.delivery) == .delivered)
        #expect(problems.isEmpty)
        #expect(delivered == [s.delivery.item.messageID])
    }

    @Test func deliver_readOnlyOpenBook_isUnavailable() async throws {
        let s = try await setup()
        defer { s.h.tearDown() }
        let document = try await s.books.open(s.entry.id, readOnly: true)
        #expect(document.isReadOnly)
        #expect(await s.writer.deliver(s.delivery) == .bookUnavailable)
        #expect(document.content.sessions[s.sessionID]?.versions.isEmpty == true)
        await s.books.close(s.entry.id)
    }

    @Test func deliver_trashedBook_isGone() async throws {
        let s = try await setup()
        defer { s.h.tearDown() }
        // Moved out of the library folder (as the Trash does).
        let trash = s.h.dir.appending(path: "Trash", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: s.entry.url, to: trash.appending(path: s.entry.url.lastPathComponent))
        #expect(await s.writer.deliver(s.delivery) == .bookGone)
    }

    @Test func deliver_openBook_keepsTheCostID() async throws {
        let s = try await setup()
        defer { s.h.tearDown() }
        let document = try await s.books.open(s.entry.id)
        #expect(await s.writer.deliver(s.delivery) == .delivered)
        let version = try #require(document.content.sessions[s.sessionID]?.versions.first)
        #expect(version.provenance?.cost == s.delivery.costRecordID)
        await s.books.close(s.entry.id)
    }
}
