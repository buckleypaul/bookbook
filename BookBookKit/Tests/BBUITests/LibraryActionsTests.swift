import BBModel
import BBStore
import Foundation
import Testing
@testable import BBUI

/// AppModel's library actions against real packages in a temp folder (PD §8.1).
@MainActor
struct LibraryActionsTests {
    @MainActor struct Setup {
        var dir: URL
        var app: AppModel
        var defaults: UserDefaults
        var suiteName: String
        var root: URL { dir.appending(path: "Library", directoryHint: .isDirectory) }

        func tearDown() async {
            await app.index.stopWatching()
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: dir)
        }
    }

    func setup(books titles: [String] = ["One", "Two"]) async throws -> Setup {
        let dir = FileManager.default.temporaryDirectory.appending(path: "bbui-library-\(UUID().uuidString)")
        let root = dir.appending(path: "Library", directoryHint: .isDirectory)
        let library = Library(root: root)
        for title in titles { _ = try library.createBook(title: title, now: Fixtures.date) }
        let suiteName = "bbui-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let app = AppModel(providers: [:], libraryRoot: root, keychainService: "app.bookbook.tests-\(UUID())",
                           indexCacheURL: dir.appending(path: "library-index.json"), userDefaults: defaults,
                           thumbnails: ThumbnailCache(root: dir.appending(path: "Caches")),
                           appSupport: AppSupportFiles(folderURL: dir.appending(path: "AppSupport")))
        await app.start()
        return Setup(dir: dir, app: app, defaults: defaults, suiteName: suiteName)
    }

    func entry(_ app: AppModel, titled title: String) throws -> LibraryEntry {
        try #require(app.libraryEntries.first { $0.title == title })
    }

    @Test func start_listsTheBooksFromTheIndex() async throws {
        let s = try await setup()
        defer { Task { await s.tearDown() } }
        #expect(Set(s.app.libraryEntries.map(\.title)) == ["One", "Two"])
        let id = try entry(s.app, titled: "One").id
        #expect(await s.app.openBooks.packageURL(for: id) == (try entry(s.app, titled: "One").url))
    }

    @Test func rename_closedBook_goesThroughTheLibrary() async throws {
        let s = try await setup()
        defer { Task { await s.tearDown() } }
        try await s.app.rename(try entry(s.app, titled: "One"), to: "  Uno ")
        let renamed = try entry(s.app, titled: "Uno")
        #expect(renamed.url.lastPathComponent == "One.bookbook")
        #expect(try await BookStore(packageURL: renamed.url).load().book.title == "Uno")
    }

    @Test func rename_openBook_goesThroughTheDocument_notUndoable() async throws {
        let s = try await setup()
        defer { Task { await s.tearDown() } }
        let one = try entry(s.app, titled: "One")
        let document = try await s.app.openBook(one.id)
        let undo = UndoManager()
        document.undoManager = undo
        try await s.app.rename(one, to: "Uno")
        #expect(document.content.book.title == "Uno")
        #expect(!undo.canUndo)
        #expect(try await BookStore(packageURL: one.url).load().book.title == "Uno")
        #expect(s.app.entry(for: one.id)?.title == "Uno")
        await s.app.closeBook(one.id)
    }

    @Test func duplicate_flushesAnOpenSourceFirst() async throws {
        let s = try await setup()
        defer { Task { await s.tearDown() } }
        let one = try entry(s.app, titled: "One")
        let document = try await s.app.openBook(one.id)
        let page = try #require(document.content.book.pageOrder.first)
        let pageValue = try #require(document.content.pages[page])
        let box = try #require(document.content.template(for: pageValue)?.textBoxes.first?.id)
        #expect(document.perform(.setRichText(page: page, box: box, text: RichText(plain: "flushed"))))
        let copy = try await s.app.duplicate(one)
        #expect(copy.id != one.id)
        #expect(s.app.libraryEntries.contains { $0.id == copy.id })
        let copied = try await BookStore(packageURL: copy.url).load()
        #expect(copied.pages[page]?.text[box] == RichText(plain: "flushed"))
        await s.app.closeBook(one.id)
    }

    @Test func trash_closesTheOpenBook_andDropsItFromTheList() async throws {
        let s = try await setup()
        defer { Task { await s.tearDown() } }
        let one = try entry(s.app, titled: "One")
        _ = try await s.app.openBook(one.id)
        #expect(s.app.openBooks.openBookIDs == [one.id])
        let trashed = try await s.app.trash(one)
        defer { if let trashed { try? FileManager.default.removeItem(at: trashed) } }
        #expect(s.app.openBooks.document(for: one.id) == nil)
        #expect(s.app.windowCloseRequests.contains(one.id))
        #expect(s.app.openBooks.openBookIDs.isEmpty)
        #expect(!s.app.libraryEntries.contains { $0.id == one.id })
        #expect(!FileManager.default.fileExists(atPath: one.url.path(percentEncoded: false)))
        s.app.windowDidClose(one.id)
        #expect(s.app.windowCloseRequests.isEmpty)
    }

    @Test func changeLibraryLocation_movingBooks_closesThem_andSavesThePath() async throws {
        let s = try await setup(books: ["One", "Two", "Three"])
        defer { Task { await s.tearDown() } }
        let one = try entry(s.app, titled: "One")
        _ = try await s.app.openBook(one.id)
        let newRoot = s.dir.appending(path: "Moved", directoryHint: .isDirectory)
        try await s.app.changeLibraryLocation(to: newRoot, moveBooks: true)
        #expect(s.app.openBooks.documents.isEmpty)
        #expect(s.app.windowCloseRequests == [one.id])
        #expect(s.app.libraryRoot == newRoot.standardizedFileURL)
        #expect(s.defaults.string(forKey: LibraryLocation.defaultsKey) == newRoot.standardizedFileURL.path(percentEncoded: false))
        #expect(Set(s.app.libraryEntries.map(\.title)) == ["One", "Two", "Three"])
        #expect(s.app.libraryEntries.allSatisfy {
            $0.url.deletingLastPathComponent().standardizedFileURL.path == newRoot.standardizedFileURL.path
        })
        // New books go to the new folder.
        let created = try await s.app.createBook(title: "Four")
        #expect(created.url.deletingLastPathComponent().standardizedFileURL.path == newRoot.standardizedFileURL.path)
    }

    @Test func changeLibraryLocation_withoutMoving_leavesTheBooks() async throws {
        let s = try await setup()
        defer { Task { await s.tearDown() } }
        let newRoot = s.dir.appending(path: "Empty", directoryHint: .isDirectory)
        try await s.app.changeLibraryLocation(to: newRoot, moveBooks: false)
        #expect(s.app.libraryEntries.isEmpty)
        #expect(Library(root: s.root).scan().count == 2)
    }

    @Test func libraryLocation_precedence() throws {
        let suiteName = "bbui-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        #expect(LibraryLocation.resolve(arguments: [:], defaults: defaults) == Library.defaultRoot)
        defaults.set("/tmp/saved", forKey: LibraryLocation.defaultsKey)
        #expect(LibraryLocation.resolve(arguments: [:], defaults: defaults).path == "/tmp/saved")
        let argued = LibraryLocation.resolve(arguments: [LibraryLocation.argumentKey: "/tmp/arg"], defaults: defaults)
        #expect(argued.path == "/tmp/arg")
    }
}

/// Read-only books and the library thumbnail (BookDocument, A §5.1, §5.3).
@MainActor
struct BookDocumentLockAndThumbnailTests {
    func makeDocument(readOnly: Bool = false, interval: Duration = .seconds(3)) throws -> (BookDocument, URL) {
        let content = Fixtures.book()
        let url = FileManager.default.temporaryDirectory.appending(path: "bbui-doc-\(UUID().uuidString).bookbook")
        try BookStore.create(content, at: url)
        let document = BookDocument(content: content, store: BookStore(packageURL: url, debounce: .milliseconds(20)),
                                    readOnly: readOnly, thumbnailInterval: interval)
        return (document, url)
    }

    @Test func readOnly_blocksEveryEdit() throws {
        let (document, url) = try makeDocument(readOnly: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let before = document.content
        let page = Fixtures.firstPage(before)
        #expect(!document.perform(.setRichText(page: page, box: Fixtures.textBox.id, text: RichText(plain: "x"))))
        document.performIrreversible { content in
            content.book.title = "changed"
            return DirtySet(book: true)
        }
        #expect(!document.rename(to: "Other"))
        #expect(document.content == before)
        #expect(!document.isEditable)
    }

    @Test func close_stopsEdits() async throws {
        let (document, url) = try makeDocument()
        defer { try? FileManager.default.removeItem(at: url) }
        await document.close()
        #expect(document.isClosed)
        #expect(!document.perform(.setRichText(page: Fixtures.firstPage(document.content), box: Fixtures.textBox.id,
                                               text: RichText(plain: "x"))))
    }

    @Test func thumbnail_isWrittenAtMostOncePerInterval_andOnFlush() async throws {
        let (document, url) = try makeDocument(interval: .milliseconds(150))
        defer { try? FileManager.default.removeItem(at: url) }
        var renders = 0
        document.renderThumbnail = { _, _ in
            renders += 1
            return Data([0x89])
        }
        let page = Fixtures.firstPage(document.content)
        for n in 0..<5 {
            document.perform(.setRichText(page: page, box: Fixtures.textBox.id, text: RichText(plain: "\(n)")))
        }
        #expect(renders == 0)
        for _ in 0..<50 where renders == 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(renders == 1)
        await document.flush()
        #expect(renders == 1) // Nothing changed since.
        document.perform(.setRichText(page: page, box: Fixtures.textBox.id, text: RichText(plain: "again")))
        await document.flush()
        #expect(renders == 2)
        #expect(!document.thumbnailDirty)
    }

    @Test func readOnly_neverRendersAThumbnail() async throws {
        let (document, url) = try makeDocument(readOnly: true, interval: .milliseconds(10))
        defer { try? FileManager.default.removeItem(at: url) }
        var renders = 0
        document.renderThumbnail = { _, _ in
            renders += 1
            return nil
        }
        await document.close()
        #expect(renders == 0)
    }
}
