import BBModel
import Darwin
import Foundation
import Testing
@testable import BBStore

/// Phase 16b lock fixes: PID reuse (#99a), host UUID and "Open Anyway" takeover (#99b),
/// symlink-safe holder counts (#105b), dropped stores (#105c), and the in-process-exclusive
/// acquire used by duplicate-ID resolution (#3b, #3c).
@Suite(.cheapSync) struct Phase16bLockTests {
    private func makeBook() throws -> (dir: URL, url: URL, content: BookContent) {
        let dir = try makeTempDir()
        let url = dir.appending(path: "B.bookbook")
        let content = try sampleContent()
        try BookStore.create(content, at: url)
        return (dir, url, content)
    }

    private func lockURL(_ url: URL) -> URL { url.appending(path: BookLock.fileName) }

    private func readLock(_ url: URL) throws -> LockOwner {
        try PackageCoding.decoder().decode(LockOwner.self, from: Data(contentsOf: lockURL(url)))
    }

    private func writeLock(_ owner: LockOwner, _ url: URL) throws {
        try PackageCoding.encoder().encode(owner).write(to: lockURL(url))
    }

    private func deadPID() throws -> Int32 {
        for pid in stride(from: Int32(99_998), to: 50_000, by: -1) where kill(pid, 0) == -1 && errno == ESRCH {
            return pid
        }
        throw CocoaError(.featureUnsupported)
    }

    // MARK: #99a PID reuse

    @Test func reusedPIDStartedAfterLockIsStale() {
        let acquired = Date(timeIntervalSinceNow: -3600)
        let owner = LockOwner(pid: getpid(), host: BookLock.currentHost, acquiredAt: acquired,
                              hostID: BookLock.currentHostID)
        // The PID's process started after the lock was taken: someone else's process now.
        #expect(!BookLock.isLive(owner, startTime: { _ in acquired.addingTimeInterval(60) }))
        // Started before (or within the slack): the lock's own process.
        #expect(BookLock.isLive(owner, startTime: { _ in acquired.addingTimeInterval(-60) }))
        #expect(BookLock.isLive(owner, startTime: { _ in acquired.addingTimeInterval(1) }))
        // Unknown start time: assume live.
        #expect(BookLock.isLive(owner, startTime: { _ in nil }))
    }

    @Test func processStartTimeComesFromSysctl() throws {
        let mine = try #require(BookLock.processStartTime(getpid()))
        #expect(mine <= Date())
        #expect(mine > Date(timeIntervalSinceNow: -86_400 * 30))
        #expect(BookLock.processStartTime(try deadPID()) == nil)
    }

    /// End to end with the real start time: launchd (PID 1) started at boot, after a lock dated 2023.
    @Test func lockOlderThanItsPIDsProcessIsTakenOver() async throws {
        let (dir, url, _) = try makeBook()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeLock(LockOwner(pid: 1, host: BookLock.currentHost, acquiredAt: testNow), url)
        let store = BookStore(packageURL: url)
        #expect(try await store.acquireLock() == .acquired)
        #expect(try readLock(url).pid == getpid())
        await store.releaseLock()
    }

    // MARK: #99b host UUID and takeover

    @Test func newLocksCarryTheHostUUID() async throws {
        let (dir, url, _) = try makeBook()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = try #require(BookLock.currentHostID)
        #expect(UUID(uuidString: id) != nil)
        let store = BookStore(packageURL: url)
        #expect(try await store.acquireLock() == .acquired)
        #expect(try readLock(url).hostID == id)
        await store.releaseLock()
    }

    @Test func legacyLockWithoutHostIDDecodes() throws {
        let json = #"{"pid":42,"host":"old-mac","acquiredAt":"2023-11-14T22:13:20Z"}"#
        let owner = try PackageCoding.decoder().decode(LockOwner.self, from: Data(json.utf8))
        #expect(owner.pid == 42 && owner.host == "old-mac" && owner.hostID == nil)
        // nil is omitted when written back, so older builds still read it.
        let text = String(decoding: try PackageCoding.encoder().encode(owner), as: UTF8.self)
        #expect(!text.contains("hostID"))
        let round = try PackageCoding.decoder().decode(
            LockOwner.self, from: PackageCoding.encoder().encode(LockOwner(pid: 1, host: "h", acquiredAt: testNow, hostID: "X")))
        #expect(round.hostID == "X")
    }

    /// A host-name change no longer makes this Mac's own crashed lock look foreign.
    @Test func ownCrashedLockUnderOldHostNameIsStale() async throws {
        let (dir, url, _) = try makeBook()
        defer { try? FileManager.default.removeItem(at: dir) }
        let hostID = try #require(BookLock.currentHostID)
        try writeLock(LockOwner(pid: try deadPID(), host: "renamed-mac.local", acquiredAt: Date(), hostID: hostID), url)
        let store = BookStore(packageURL: url)
        #expect(try await store.acquireLock() == .acquired)
        await store.releaseLock()
    }

    /// Same host name but another Mac's UUID: foreign, so live (its PID means nothing here).
    @Test func sameNameDifferentHostIDIsForeign() {
        let owner = LockOwner(pid: (try? deadPID()) ?? 2, host: BookLock.currentHost, acquiredAt: Date(),
                              hostID: UUID().uuidString)
        #expect(BookLock.isLive(owner))
    }

    @Test func takeOverLockWhenOwnerStillMatches() async throws {
        let (dir, url, _) = try makeBook()
        defer { try? FileManager.default.removeItem(at: dir) }
        let foreign = LockOwner(pid: 4242, host: "another-mac.example", acquiredAt: testNow, hostID: UUID().uuidString)
        try writeLock(foreign, url)
        let store = BookStore(packageURL: url)
        #expect(try await store.acquireLock() == .heldByOther(foreign))
        #expect(try await store.takeOverLock(expectedOwner: foreign) == .acquired)
        let now = try readLock(url)
        #expect(now.pid == getpid() && now.hostID == BookLock.currentHostID)
        // Held like any other acquire: counted, and released normally.
        #expect(try await store.takeOverLock(expectedOwner: foreign) == .acquired)
        await store.releaseLock()
        #expect(!exists(lockURL(url)))
    }

    @Test func takeOverLockRefusesWhenOwnerChanged() async throws {
        let (dir, url, _) = try makeBook()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = LockOwner(pid: 4242, host: "another-mac.example", acquiredAt: testNow)
        let second = LockOwner(pid: 777, host: "third-mac.example", acquiredAt: testNow.addingTimeInterval(5))
        try writeLock(second, url)
        let store = BookStore(packageURL: url)
        #expect(try await store.takeOverLock(expectedOwner: first) == .heldByOther(second))
        #expect(try readLock(url) == second)
        await store.releaseLock() // not held: leaves the other lock alone
        #expect(try readLock(url) == second)
    }

    @Test func takeOverLockCreatesWhenLockWasReleased() async throws {
        let (dir, url, _) = try makeBook()
        defer { try? FileManager.default.removeItem(at: dir) }
        let gone = LockOwner(pid: 4242, host: "another-mac.example", acquiredAt: testNow)
        let store = BookStore(packageURL: url)
        #expect(try await store.takeOverLock(expectedOwner: gone) == .acquired)
        #expect(try readLock(url).pid == getpid())
        await store.releaseLock()
        #expect(!exists(lockURL(url)))
    }

    // MARK: #105b symlinks, #105c dropped stores

    @Test func symlinkAndRealPathShareOneHolderCount() async throws {
        let (dir, url, _) = try makeBook()
        defer { try? FileManager.default.removeItem(at: dir) }
        let link = dir.appending(path: "Link.bookbook")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        let viaLink = BookStore(packageURL: link)
        let direct = BookStore(packageURL: url)
        #expect(try await viaLink.acquireLock() == .acquired)
        #expect(try await direct.acquireLock() == .acquired)
        await viaLink.releaseLock()
        #expect(exists(lockURL(url)))
        await direct.releaseLock()
        #expect(!exists(lockURL(url)))
    }

    @Test func droppedStoreReleasesItsHold() async throws {
        let (dir, url, _) = try makeBook()
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            let store = BookStore(packageURL: url)
            #expect(try await store.acquireLock() == .acquired)
            #expect(exists(lockURL(url)))
        }
        // `deinit` runs when the last reference goes; allow the runtime a moment.
        for _ in 0..<100 where exists(lockURL(url)) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!exists(lockURL(url)))
        #expect(!BookLock(packageURL: url).isHeldInProcess)
    }

    // MARK: #3b, #3c in-process-exclusive acquire

    @Test func exclusiveAcquireRefusesWhileAnotherStoreHoldsIt() async throws {
        let (dir, url, _) = try makeBook()
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = BookStore(packageURL: url)
        let job = BookStore(packageURL: url)
        #expect(try await app.acquireLock() == .acquired)
        guard case .heldByOther(let owner) = try await job.acquireLockExclusively() else {
            Issue.record("expected heldByOther")
            return
        }
        #expect(BookLock.isCurrentProcess(owner))
        await job.releaseLock() // not held: no effect
        #expect(exists(lockURL(url)))
        await app.releaseLock()
        #expect(!exists(lockURL(url)))
        #expect(try await job.acquireLockExclusively() == .acquired)
        await job.releaseLock()
        #expect(!exists(lockURL(url)))
    }

    /// The file names this process but no store counts it (e.g. left by a store that leaked):
    /// exclusive acquire treats it as busy, as specified.
    @Test func exclusiveAcquireRefusesOwnUncountedLock() async throws {
        let (dir, url, _) = try makeBook()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeLock(BookLock.currentOwner(), url)
        let job = BookStore(packageURL: url)
        guard case .heldByOther = try await job.acquireLockExclusively() else {
            Issue.record("expected heldByOther")
            return
        }
    }

    /// The resolver skips a package whose lock a store in this process holds, even when it is not
    /// in the `open` hint (still opening, or a headless delivery writing to it).
    @Test func resolverSkipsPackageLockedInThisProcess() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let lib = Library(root: dir.appending(path: "Library", directoryHint: .isDirectory))
        let a = try lib.createBook(title: "Fox", now: testNow)
        let copy = a.url.deletingLastPathComponent().appending(path: "Fox copy.bookbook", directoryHint: .isDirectory)
        try FileManager.default.copyItem(at: a.url, to: copy)
        let before = try Data(contentsOf: copy.appending(path: PackageCoding.bookPath))

        let holder = BookStore(packageURL: copy)
        #expect(try await holder.acquireLock() == .acquired)
        // `a` is the keeper, so only the copy would be rewritten, and it's held here.
        #expect(await lib.resolveDuplicateBookIDs(preferring: [a.id: a.url]).isEmpty)
        #expect(try Data(contentsOf: copy.appending(path: PackageCoding.bookPath)) == before)
        #expect(!exists(copy.appending(path: ".journal")))
        #expect(exists(lockURL(copy)))

        await holder.releaseLock()
        let changed = await lib.resolveDuplicateBookIDs(preferring: [a.id: a.url])
        #expect(changed.map(\.url.lastPathComponent) == [copy.lastPathComponent])
    }
}
