import BBModel
import Foundation
import Testing
@testable import BBStore

@Suite struct DuplicateBookIDTests {
    private func makeLibrary() throws -> (Library, URL) {
        let dir = try makeTempDir()
        return (Library(root: dir.appending(path: "Library", directoryHint: .isDirectory)), dir)
    }

    /// Finder-style copy: same bytes, same book.json.
    private func finderCopy(_ entry: LibraryEntry, as name: String) throws -> URL {
        let dest = entry.url.deletingLastPathComponent().appending(path: "\(name).bookbook", directoryHint: .isDirectory)
        try FileManager.default.copyItem(at: entry.url, to: dest)
        return dest
    }

    @Test func copyGetsNewIDOnceAndOriginalKeepsIt() async throws {
        let (lib, dir) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try lib.createBook(title: "Fox", now: testNow)
        let copyURL = try finderCopy(a, as: "Fox copy")
        #expect(Set(lib.scan().map(\.id)).count == 1)

        let changed = await lib.resolveDuplicateBookIDs(preferring: [a.id: a.url])
        #expect(changed.count == 1)
        #expect(changed[0].url.lastPathComponent == copyURL.lastPathComponent && changed[0].id != a.id)

        let scanned = lib.scan()
        #expect(scanned.count == 2 && Set(scanned.map(\.id)).count == 2)
        #expect(scanned.first { $0.url.lastPathComponent == a.url.lastPathComponent }?.id == a.id)
        #expect(scanned.first { $0.url.lastPathComponent == copyURL.lastPathComponent }?.id == changed[0].id)
        #expect(scanned.first { $0.url.lastPathComponent == copyURL.lastPathComponent }?.modifiedAt == a.modifiedAt)
        #expect(!exists(copyURL.appending(path: ".lock")))

        // Second pass: nothing more to do.
        #expect(await lib.resolveDuplicateBookIDs().isEmpty)
        let loaded = try await BookStore(packageURL: copyURL).load()
        #expect(loaded.book.id == changed[0].id)
    }

    @Test func keeperIsTheIndexedPackageEvenIfItsNameSortsLater() async throws {
        let (lib, dir) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try lib.createBook(title: "Zebra", now: testNow)
        let copyURL = try finderCopy(a, as: "Aardvark")
        let changed = await lib.resolveDuplicateBookIDs(preferring: [a.id: a.url])
        #expect(changed.map { $0.url.lastPathComponent } == [copyURL.lastPathComponent])
        #expect(lib.scan().first { $0.url.lastPathComponent == a.url.lastPathComponent }?.id == a.id)
    }

    @Test func withoutAnIndexTheDecisionIsDeterministic() throws {
        let (lib, dir) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try lib.createBook(title: "Fox", now: testNow)
        let copyURL = try finderCopy(a, as: "Fox copy")
        let group = lib.scan()
        // Same creation date is not guaranteed by the file system, so only check the stable ordering.
        let k1 = Library.keeper(in: group, preferred: nil)
        let k2 = Library.keeper(in: group.reversed(), preferred: nil)
        #expect(k1.url.lastPathComponent == k2.url.lastPathComponent)
        #expect([a.url, copyURL].map(\.lastPathComponent).contains(k1.url.lastPathComponent))
    }

    @Test func indexRefreshFixesDuplicatesAndKeepsKnownPackage() async throws {
        let (lib, dir) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try lib.createBook(title: "Zebra", now: testNow)
        let index = LibraryIndex(root: lib.root, cacheURL: dir.appending(path: "index.json"))
        await index.refresh()
        let copyURL = try finderCopy(a, as: "Aardvark")
        let entries = await index.refreshResolvingDuplicates()
        #expect(entries.count == 2 && Set(entries.map(\.id)).count == 2)
        #expect(entries.first { $0.url.lastPathComponent == a.url.lastPathComponent }?.id == a.id)
        #expect(entries.first { $0.url.lastPathComponent == copyURL.lastPathComponent }?.id != a.id)
    }
}
