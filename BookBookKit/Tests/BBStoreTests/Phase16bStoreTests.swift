import BBModel
import Foundation
import Testing
@testable import BBStore

/// Phase 16b store fixes: sweep protection (#29a), re-stored image mtime (#100), library
/// operations under the lock (#103) and the FSEvents context lifetime (#97).
@Suite(.cheapSync) struct Phase16bStoreTests {
    private func makeBook() throws -> (dir: URL, url: URL, content: BookContent) {
        let dir = try makeTempDir()
        let url = dir.appending(path: "B.bookbook")
        let content = try sampleContent()
        try BookStore.create(content, at: url)
        return (dir, url, content)
    }

    private func backdate(_ url: URL, days: Double) throws {
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -86_400 * days)],
                                              ofItemAtPath: url.path(percentEncoded: false))
    }

    // MARK: #29a

    @Test func protectedOrphanOlderThanADaySurvivesLoad() async throws {
        let (dir, url, content) = try makeBook()
        defer { try? FileManager.default.removeItem(at: dir) }
        defer { SweepProtection.shared.set([], for: content.book.id) }
        let name = String(repeating: "b", count: 64) + ".png"
        let mask = url.appending(path: "images/\(name)")
        try Data("queued mask".utf8).write(to: mask)
        try backdate(mask, days: 2)

        SweepProtection.shared.set([name], for: content.book.id)
        _ = try await BookStore(packageURL: url).load()
        #expect(exists(mask))

        // Control: once unprotected, the same open sweeps it.
        SweepProtection.shared.set([], for: content.book.id)
        _ = try await BookStore(packageURL: url).load()
        #expect(!exists(mask))
    }

    // MARK: #100

    @Test func restoringAnExistingImageRefreshesItsAge() async throws {
        let (dir, url, content) = try makeBook()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = BookStore(packageURL: url)
        let bytes = Data("same pixels".utf8)
        let ref = try await store.storeImage(bytes, contentType: "public.png")
        let file = store.imageURL(for: ref)
        try backdate(file, days: 2)
        // Stored again (identical bytes), but the JSON that refers to it isn't saved yet.
        _ = try await store.storeImage(bytes, contentType: "public.png")
        #expect(try await store.sweepOrphanImages(referencedBy: content) == 0)
        #expect(exists(file))
    }

    // MARK: #103

    private func makeLibraryBook() throws -> (Library, LibraryEntry, URL) {
        let dir = try makeTempDir()
        let lib = Library(root: dir.appending(path: "Library", directoryHint: .isDirectory))
        return (lib, try lib.createBook(title: "Fox", now: testNow), dir)
    }

    @Test func duplicateAndTrashRefuseAForeignLock() throws {
        let (lib, entry, dir) = try makeLibraryBook()
        defer { try? FileManager.default.removeItem(at: dir) }
        let foreign = LockOwner(pid: 4242, host: "another-mac.example", acquiredAt: testNow)
        try PackageCoding.encoder().encode(foreign).write(to: entry.url.appending(path: BookLock.fileName))
        #expect(throws: StoreError.locked(foreign)) { try lib.duplicate(entry) }
        #expect(throws: StoreError.locked(foreign)) { try lib.trash(entry) }
        #expect(exists(entry.url))
        #expect(lib.scan().count == 1)
    }

    @Test func duplicateIncludesACommittedJournal() async throws {
        let (lib, entry, dir) = try makeLibraryBook()
        defer { try? FileManager.default.removeItem(at: dir) }
        var changed = try await BookStore(packageURL: entry.url).load()
        changed.style.visualDescription = "committed but not yet applied"
        let files = try PackageCoding.files(for: changed, dirty: DirtySet(style: true))
        try Journal(packageURL: entry.url).run(files: files, deletions: [], apply: false)

        let copy = try lib.duplicate(entry, now: testNow)
        let loaded = try await BookStore(packageURL: copy.url).load()
        #expect(loaded.style.visualDescription == "committed but not yet applied")
        #expect(!exists(copy.url.appending(path: ".journal")))
        #expect(!exists(copy.url.appending(path: BookLock.fileName)))
        // The source was rolled forward too, and its lock released.
        #expect(!exists(entry.url.appending(path: ".journal")))
        #expect(!exists(entry.url.appending(path: BookLock.fileName)))
    }

    @Test func duplicateIsFineWhileThisProcessHoldsTheLock() async throws {
        let (lib, entry, dir) = try makeLibraryBook()
        defer { try? FileManager.default.removeItem(at: dir) }
        let open = BookStore(packageURL: entry.url)
        #expect(try await open.acquireLock() == .acquired)
        _ = try lib.duplicate(entry, now: testNow)
        #expect(exists(entry.url.appending(path: BookLock.fileName))) // still the open store's
        await open.releaseLock()
        #expect(!exists(entry.url.appending(path: BookLock.fileName)))
    }

    // MARK: #97

    /// Start and stop the watcher in a tight loop while files change, so callbacks are in
    /// flight during `stop()`. Before the fix this could touch a freed context box.
    @Test func watcherStartStopLoopWhileTouchingFiles() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appending(path: "Library", directoryHint: .isDirectory)
        let lib = Library(root: root)
        let entry = try lib.createBook(title: "Fox", now: testNow)
        let book = entry.url.appending(path: PackageCoding.bookPath)
        let toucher = Task.detached {
            var i = 0
            while !Task.isCancelled {
                try? FileManager.default.setAttributes([.modificationDate: Date()],
                                                       ofItemAtPath: book.path(percentEncoded: false))
                try? Data("\(i)".utf8).write(to: root.appending(path: "noise-\(i % 4).bookbook"))
                i += 1
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
        defer { toucher.cancel() }
        for _ in 0..<60 {
            let index = LibraryIndex(root: root, cacheURL: dir.appending(path: "cache.json"))
            _ = await index.changes()
            try await Task.sleep(for: .milliseconds(Int.random(in: 0...5)))
            await index.stopWatching()
        }
        toucher.cancel()
    }
}
