import BBModel
import Foundation
import Testing
@testable import BBStore

@Suite struct LibraryOpsTests {
    private func makeLibrary() throws -> (Library, URL) {
        let dir = try makeTempDir()
        return (Library(root: dir.appending(path: "Library", directoryHint: .isDirectory)), dir)
    }

    @Test func duplicateMakesNewBook() async throws {
        let (lib, dir) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try lib.createBook(title: "Fox", now: testNow)
        // Pretend the source is open: lock and journal must not be copied.
        try Data("{}".utf8).write(to: a.url.appending(path: ".lock"))
        try FileManager.default.createDirectory(at: a.url.appending(path: ".journal"), withIntermediateDirectories: true)
        try Data([1]).write(to: a.url.appending(path: "thumbnail.png"))

        let later = testNow.addingTimeInterval(500)
        let b = try lib.duplicate(a, now: later)
        let c = try lib.duplicate(a, now: later)
        #expect(b.id != a.id)
        #expect(b.title == "Fox copy")
        #expect(c.title == "Fox copy 2")
        #expect(b.url.lastPathComponent == "Fox copy.bookbook")
        #expect(b.modifiedAt == later)
        #expect(!exists(b.url.appending(path: ".lock")))
        #expect(!exists(b.url.appending(path: ".journal")))
        #expect(b.thumbnailURL != nil)
        #expect(exists(a.url.appending(path: ".lock")))

        let loaded = try await BookStore(packageURL: b.url).load()
        #expect(loaded.book.id == b.id)
        #expect(loaded.book.title == "Fox copy")
        #expect(lib.scan().count == 3)
    }

    @Test func renameKeepsFolder() throws {
        let (lib, dir) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try lib.createBook(title: "Fox", now: testNow)
        let later = testNow.addingTimeInterval(60)
        let r = try lib.rename(a, to: "Badger", now: later)
        #expect(r.title == "Badger")
        #expect(r.url == a.url)
        #expect(r.id == a.id)
        #expect(r.modifiedAt == later)
        #expect(exists(a.url))
        let scanned = try #require(lib.scan().first)
        #expect(scanned.title == "Badger")
        #expect(scanned.modifiedAt == later)
        #expect(!exists(a.url.appending(path: ".lock")))
    }

    @Test func trashReturnsTrashURL() throws {
        let (lib, dir) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try lib.createBook(title: "Trash me \(UUID().uuidString)")
        let trashed = try lib.trash(a)
        #expect(!exists(a.url))
        let url = try #require(trashed)
        #expect(exists(url))
        try FileManager.default.removeItem(at: url) // leave the real Trash clean
        #expect(!exists(url))
    }

    @Test func moveBooksHandlesClash() throws {
        let (lib, dir) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try lib.createBook(title: "Fox")
        _ = try lib.createBook(title: "Owl")
        let newRoot = dir.appending(path: "New", directoryHint: .isDirectory)
        let other = Library(root: newRoot)
        _ = try other.createBook(title: "Fox")

        let moved = try lib.moveBooks(to: newRoot)
        #expect(Set(moved.map(\.lastPathComponent)) == ["Fox 2.bookbook", "Owl.bookbook"])
        #expect(moved.allSatisfy { exists($0) })
        #expect(!exists(a.url))
        #expect(lib.scan().isEmpty)
        #expect(other.scan().count == 3)
    }
}
