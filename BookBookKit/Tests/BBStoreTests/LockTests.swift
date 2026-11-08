import BBModel
import Darwin
import Foundation
import Testing
@testable import BBStore

/// `.lock` single-writer handling and read-only mode (A §5.3).
@Suite(.cheapSync) struct LockTests {
    private func makeBook() throws -> (dir: URL, url: URL, content: BookContent) {
        let dir = try makeTempDir()
        let url = dir.appending(path: "B.bookbook")
        let content = try sampleContent()
        try BookStore.create(content, at: url)
        return (dir, url, content)
    }

    private func lockURL(_ url: URL) -> URL { url.appending(path: ".lock") }

    private func readLock(_ url: URL) throws -> LockOwner {
        try PackageCoding.decoder().decode(LockOwner.self, from: Data(contentsOf: lockURL(url)))
    }

    private func writeLock(_ owner: LockOwner, _ url: URL) throws {
        try PackageCoding.encoder().encode(owner).write(to: lockURL(url))
    }

    /// A PID with no process right now (found with `kill(pid, 0)`; nothing is spawned).
    private func deadPID() throws -> Int32 {
        for pid in stride(from: Int32(99_998), to: 50_000, by: -1) where kill(pid, 0) == -1 && errno == ESRCH {
            return pid
        }
        throw CocoaError(.featureUnsupported)
    }

    @Test func freshAcquireWritesOwnerAndReleaseRemovesIt() async throws {
        let (dir, url, _) = try makeBook()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = BookStore(packageURL: url)
        #expect(try await store.acquireLock() == .acquired)
        let owner = try readLock(url)
        #expect(owner.pid == getpid())
        #expect(owner.host == BookLock.currentHost)
        #expect(try await store.acquireLock() == .acquired) // idempotent
        // No temp files left beside it.
        let names = try FileManager.default.contentsOfDirectory(atPath: url.path(percentEncoded: false))
        #expect(!names.contains { $0.hasPrefix(".lock.tmp") })

        await store.releaseLock()
        #expect(!exists(lockURL(url)))
        await store.releaseLock() // safe twice
    }

    @Test func reentrantAcquireFromThisProcessDoesNotStealTheFile() async throws {
        let (dir, url, _) = try makeBook()
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = BookStore(packageURL: url)
        let headless = BookStore(packageURL: url)
        #expect(try await app.acquireLock() == .acquired)
        let owner = try readLock(url)
        #expect(try await headless.acquireLock() == .acquired)
        #expect(try readLock(url) == owner)
        // The headless store releasing does not drop the app's lock.
        await headless.releaseLock()
        #expect(try readLock(url) == owner)
        await app.releaseLock()
        #expect(!exists(lockURL(url)))
    }

    @Test func staleLockWithDeadPIDIsTakenOver() async throws {
        let (dir, url, _) = try makeBook()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stale = LockOwner(pid: try deadPID(), host: BookLock.currentHost, acquiredAt: testNow)
        try writeLock(stale, url)
        let store = BookStore(packageURL: url)
        #expect(try await store.acquireLock() == .acquired)
        #expect(try readLock(url).pid == getpid())
        await store.releaseLock()
        #expect(!exists(lockURL(url)))
    }

    @Test func garbageLockIsTakenOver() async throws {
        let (dir, url, _) = try makeBook()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("not json".utf8).write(to: lockURL(url))
        let store = BookStore(packageURL: url)
        #expect(try await store.acquireLock() == .acquired)
        #expect(try readLock(url).pid == getpid())
    }

    @Test(arguments: ["other-host.example", nil as String?])
    func liveLockIsHeldByOther(host: String?) async throws {
        let (dir, url, _) = try makeBook()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Another host (any PID, even a dead one), or PID 1 (launchd) on this host.
        let live = host.map { LockOwner(pid: (try? deadPID()) ?? 2, host: $0, acquiredAt: testNow) }
            ?? LockOwner(pid: 1, host: BookLock.currentHost, acquiredAt: testNow)
        try writeLock(live, url)
        let store = BookStore(packageURL: url)
        #expect(try await store.acquireLock() == .heldByOther(live))
        // Not holding it, so release leaves the other process's lock alone.
        await store.releaseLock()
        #expect(try readLock(url) == live)
    }

    @Test func readOnlyRefusesWritesAndDoesNotReplayJournal() async throws {
        let (dir, url, content) = try makeBook()
        defer { try? FileManager.default.removeItem(at: dir) }
        let other = LockOwner(pid: 1, host: BookLock.currentHost, acquiredAt: testNow)
        try writeLock(other, url)
        // A committed, unapplied transaction from the other writer.
        var changed = content
        changed.book.title = "Changed elsewhere"
        let files = try PackageCoding.files(for: changed, dirty: DirtySet(book: true))
        let tx = try Journal(packageURL: url).run(files: files, deletions: [], apply: false)
        // An old orphan the sweep would otherwise remove.
        let orphan = url.appending(path: "images/\(String(repeating: "a", count: 64)).png")
        try Data("orphan".utf8).write(to: orphan)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -200_000)],
                                              ofItemAtPath: orphan.path(percentEncoded: false))

        let store = BookStore(packageURL: url)
        #expect(try await store.acquireLock() == .heldByOther(other))
        await store.setReadOnly()
        #expect(await store.isReadOnly)
        let loaded = try await store.load()
        #expect(loaded == content) // journal left alone
        #expect(exists(tx.appending(path: "COMMIT")))
        #expect(exists(orphan))

        await #expect(throws: StoreError.readOnly) { try await store.save(changed, dirty: DirtySet(book: true)) }
        await #expect(throws: StoreError.readOnly) { try await store.storeImage(Data("x".utf8), contentType: "public.png") }
        await #expect(throws: StoreError.readOnly) { try await store.writeThumbnail(Data("png".utf8)) }
        #expect(try await store.sweepOrphanImages(referencedBy: loaded, minimumAge: 0) == 0)

        let results = ResultBox()
        await store.setAutosaveResultHandler { results.add($0) }
        await store.scheduleSave(changed, dirty: DirtySet(book: true), generation: 1)
        #expect(results.all == [.readOnly])
        try await store.flush() // nothing pending
        #expect(results.all == [.readOnly])
        #expect(try readLock(url) == other)
        #expect(!exists(store.thumbnailURL))

        // The writer replays it on its next open.
        try FileManager.default.removeItem(at: lockURL(url))
        #expect(try await BookStore(packageURL: url).load().book.title == "Changed elsewhere")
    }

    @Test func writeThumbnailIsAtomicAndNotSwept() async throws {
        let (dir, url, content) = try makeBook()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = BookStore(packageURL: url)
        try await store.writeThumbnail(Data("one".utf8))
        try await store.writeThumbnail(Data("two".utf8))
        #expect(try Data(contentsOf: store.thumbnailURL) == Data("two".utf8))
        let names = try FileManager.default.contentsOfDirectory(atPath: url.path(percentEncoded: false))
        #expect(!names.contains { $0.contains(".tmp-") })
        #expect(try await store.acquireLock() == .acquired)
        try await store.sweepOrphanImages(referencedBy: content, minimumAge: 0)
        #expect(exists(store.thumbnailURL))
        #expect(exists(lockURL(url)))
    }
}

private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [StoreError?] = []
    func add(_ e: StoreError?) { lock.lock(); items.append(e); lock.unlock() }
    var all: [StoreError?] { lock.lock(); defer { lock.unlock() }; return items }
}
