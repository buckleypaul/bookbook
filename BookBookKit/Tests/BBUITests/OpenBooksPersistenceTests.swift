import BBModel
import BBStore
import Foundation
import Testing
@testable import BBUI

/// The open-books list that is reopened at relaunch (A §6.1, PD §8.1).
@MainActor
struct OpenBooksPersistenceTests {
    @MainActor struct Setup {
        var root: URL
        var library: Library
        var suiteName: String
        var defaults: UserDefaults
        var entries: [LibraryEntry]

        func makeBooks() -> OpenBooks { OpenBooks(library: library, defaults: defaults) }
        func ids(_ indices: Int...) -> [BookID] { indices.map { entries[$0].id } }

        func tearDown() {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
    }

    func setup(books: Int = 3) throws -> Setup {
        let root = FileManager.default.temporaryDirectory.appending(path: "bbui-openlist-\(UUID().uuidString)")
        let library = Library(root: root)
        let entries = try (0..<books).map { try library.createBook(title: "Book \($0)", now: Fixtures.date) }
        let suiteName = "bbui-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return Setup(root: root, library: library, suiteName: suiteName, defaults: defaults, entries: entries)
    }

    @Test func openAndClose_keepTheOrderedList_andPersistIt() async throws {
        let s = try setup()
        defer { s.tearDown() }
        let books = s.makeBooks()
        for entry in s.entries { _ = try await books.open(entry.id) }
        #expect(books.openBookIDs == s.ids(0, 1, 2))
        await books.close(s.entries[1].id)
        #expect(books.openBookIDs == s.ids(0, 2))
        #expect(s.makeBooks().openBookIDs == s.ids(0, 2))
        #expect(s.defaults.stringArray(forKey: OpenBooks.openBookIDsKey)
            == s.ids(0, 2).map(\.rawValue.uuidString))
    }

    @Test func closingWhileQuitting_keepsTheEntries() async throws {
        let s = try setup()
        defer { s.tearDown() }
        let books = s.makeBooks()
        _ = try await books.open(s.entries[2].id)
        _ = try await books.open(s.entries[0].id)
        await books.closeAllForQuit()
        #expect(books.documents.isEmpty)
        // The windows then close as the app exits.
        await books.close(s.entries[2].id)
        await books.close(s.entries[0].id)
        #expect(s.makeBooks().openBookIDs == s.ids(2, 0))
    }

    @Test func terminatingFlag_alone_keepsEntriesWhenWindowsCloseFirst() async throws {
        let s = try setup()
        defer { s.tearDown() }
        let books = s.makeBooks()
        _ = try await books.open(s.entries[0].id)
        books.isTerminating = true
        await books.close(s.entries[0].id)
        #expect(books.document(for: s.entries[0].id) == nil)
        #expect(s.makeBooks().openBookIDs == s.ids(0))
    }

    @Test func booksToReopen_dropsUnresolvableIDs_inOrder() throws {
        let s = try setup()
        defer { s.tearDown() }
        let gone = BookID()
        s.defaults.set([s.entries[2].id, gone, s.entries[0].id].map(\.rawValue.uuidString) + ["not-a-uuid"],
                       forKey: OpenBooks.openBookIDsKey)
        let books = s.makeBooks()
        let known = Set(s.entries.map(\.id))
        #expect(books.booksToReopen { known.contains($0) } == s.ids(2, 0))
        #expect(s.makeBooks().openBookIDs == s.ids(2, 0))
    }

    @Test func openingTwice_addsOneEntry_andOneDocument() async throws {
        let s = try setup(books: 1)
        defer { s.tearDown() }
        let books = s.makeBooks()
        let id = s.entries[0].id
        async let first = books.open(id)
        async let second = books.open(id)
        let (a, b) = try await (first, second)
        #expect(a === b)
        _ = try await books.open(id)
        #expect(books.openBookIDs == [id])
        #expect(books.documents.count == 1)
    }

    @Test func savedDuplicates_areReadOnce() throws {
        let s = try setup(books: 1)
        defer { s.tearDown() }
        let id = s.entries[0].id.rawValue.uuidString
        s.defaults.set([id, id], forKey: OpenBooks.openBookIDsKey)
        #expect(s.makeBooks().openBookIDs == s.ids(0))
    }

    @Test func appModel_reopensResolvableBooksOnce_inOrder() async throws {
        let s = try setup()
        defer { s.tearDown() }
        let cache = s.root.deletingLastPathComponent().appending(path: "bbui-index-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cache) }
        s.defaults.set([s.entries[1].id, BookID(), s.entries[0].id].map(\.rawValue.uuidString),
                       forKey: OpenBooks.openBookIDsKey)
        let app = AppModel(providers: [:], libraryRoot: s.root, keychainService: "app.bookbook.tests-\(UUID())",
                           indexCacheURL: cache, userDefaults: s.defaults)
        var opened: [BookID] = []
        await app.reopenBooks { opened.append($0) }
        #expect(opened == s.ids(1, 0))
        await app.reopenBooks { opened.append($0) }
        #expect(opened == s.ids(1, 0))
        #expect(app.openBooks.openBookIDs == s.ids(1, 0))
        await app.index.stopWatching()
    }
}
