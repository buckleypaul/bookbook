import BBModel
import Foundation
import Synchronization
import Testing
@testable import BBStore

/// Polls `condition` until true or `timeout` elapses.
func waitUntil(timeout: Duration = .seconds(10), _ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return await condition()
}

final class TestFlag: Sendable {
    private let flag = Mutex(false)
    func set() { flag.withLock { $0 = true } }
    var isSet: Bool { flag.withLock { $0 } }
}

@Suite struct LibraryIndexTests {
    private func makeIndex() throws -> (LibraryIndex, Library, URL) {
        let dir = try makeTempDir()
        let root = dir.appending(path: "Library", directoryHint: .isDirectory)
        let cache = dir.appending(path: "cache/index.json")
        return (LibraryIndex(root: root, cacheURL: cache), Library(root: root), dir)
    }

    @Test func refreshTracksAddsAndRemoves() async throws {
        let (index, lib, dir) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(await index.refresh().isEmpty)
        let a = try lib.createBook(title: "A", now: Date(timeIntervalSince1970: 1_700_000_000))
        let b = try lib.createBook(title: "B", now: Date(timeIntervalSince1970: 1_700_000_100))
        #expect(await index.refresh().map(\.id) == [b.id, a.id])
        #expect(await index.entry(for: a.id)?.title == "A")
        try FileManager.default.removeItem(at: b.url)
        #expect(await index.refresh().map(\.id) == [a.id])
        #expect(await index.entry(for: b.id) == nil)
    }

    @Test func thumbnailURLFilledWhenPresent() async throws {
        let (index, lib, dir) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try lib.createBook(title: "A")
        #expect(await index.refresh().first?.thumbnailURL == nil)
        try Data([1, 2, 3]).write(to: a.url.appending(path: "thumbnail.png"))
        #expect(await index.refresh().first?.thumbnailURL?.lastPathComponent == "thumbnail.png")
    }

    @Test func cacheRoundTripAndWrongRoot() async throws {
        let (index, lib, dir) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try lib.createBook(title: "A")
        let fresh = await index.refresh()
        let cache = index.cacheURL

        let again = LibraryIndex(root: index.root, cacheURL: cache)
        #expect(await again.entries.isEmpty)
        #expect(await again.loadCache() == fresh)
        #expect(await again.entry(for: a.id) != nil)

        let other = LibraryIndex(root: dir.appending(path: "Elsewhere"), cacheURL: cache)
        #expect(await other.loadCache().isEmpty)

        try Data("not json".utf8).write(to: cache)
        #expect(await again.loadCache() == fresh) // garbage ignored, entries unchanged
        let blank = LibraryIndex(root: index.root, cacheURL: cache)
        #expect(await blank.loadCache().isEmpty)
    }

    /// An unchanged rescan leaves the cache file alone; a changed one replaces it (atomically,
    /// so as a new file).
    @Test func cacheRewrittenOnlyWhenEntriesChange() async throws {
        let (index, lib, dir) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: dir) }
        func fileNumber() throws -> Int? {
            try FileManager.default.attributesOfItem(atPath: index.cacheURL.path(percentEncoded: false))[.systemFileNumber] as? Int
        }
        _ = try lib.createBook(title: "A")
        await index.refresh()
        let first = try #require(try fileNumber())
        await index.refresh()
        await index.refreshResolvingDuplicates()
        #expect(try fileNumber() == first)
        _ = try lib.createBook(title: "B")
        #expect(await index.refreshResolvingDuplicates().count == 2)
        #expect(try fileNumber() != first)
    }

    /// A `refresh()` that lands while the duplicate resolver is suspended (e.g. after
    /// `AppModel.createBook`) wins: the resolving rescan must not commit its older scan over it.
    @Test func refreshDuringDuplicateResolutionIsNotOverwritten() async throws {
        let (index, lib, dir) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try lib.createBook(title: "A", now: Date(timeIntervalSince1970: 1_700_000_000))
        let (entered, enteredContinuation) = AsyncStream<Void>.makeStream()
        let (release, releaseContinuation) = AsyncStream<Void>.makeStream()
        await index.setDuplicateResolver { _, _, _, _ in
            enteredContinuation.yield()
            for await _ in release { break }
            return []
        }
        let resolving = Task { await index.refreshResolvingDuplicates() }
        for await _ in entered { break }
        let b = try lib.createBook(title: "B", now: Date(timeIntervalSince1970: 1_700_000_100))
        #expect(await index.refresh().map(\.id) == [b.id, a.id])
        releaseContinuation.yield()
        #expect(await resolving.value.map(\.id) == [b.id, a.id])
        #expect(await index.entries.map(\.id) == [b.id, a.id])
        let cached = LibraryIndex(root: index.root, cacheURL: index.cacheURL)
        #expect(await cached.loadCache().map(\.id) == [b.id, a.id])
    }

    @Test func changesYieldsAfterPackageCopiedIn() async throws {
        let (index, lib, dir) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: dir) }
        // A package built elsewhere, then copied into the watched root.
        let staging = Library(root: dir.appending(path: "Staging", directoryHint: .isDirectory))
        let incoming = try staging.createBook(title: "Incoming")
        let stream = await index.changes()
        let got = TestFlag()
        let incomingID = incoming.id
        let reader = Task {
            for await entries in stream where entries.contains(where: { $0.id == incomingID }) {
                got.set()
                return
            }
        }
        try await Task.sleep(for: .milliseconds(500)) // let the stream start
        try FileManager.default.copyItem(at: incoming.url, to: lib.root.appending(path: "Incoming.bookbook"))

        let ok = await waitUntil { got.isSet }
        reader.cancel()
        #expect(ok)
        #expect(await index.entry(for: incoming.id) != nil)
        await index.stopWatching()
    }

    @Test func stopWatchingFinishesStreams() async throws {
        let (index, _, dir) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stream = await index.changes()
        await index.stopWatching()
        var count = 0
        for await _ in stream { count += 1 }
        #expect(count == 0)
    }

    @Test func eventPathFilter() {
        let root = URL(fileURLWithPath: "/tmp/BBTestLib/Library", isDirectory: true)
        func rel(_ p: String) -> Bool { LibraryIndex.isRelevant(path: "/tmp/BBTestLib/Library/" + p, root: root) }
        #expect(rel("A.bookbook"))
        #expect(rel("A.bookbook/book.json"))
        #expect(rel("A.bookbook/thumbnail.png"))
        #expect(!rel("A.bookbook/.lock"))
        #expect(!rel("A.bookbook/.journal"))
        #expect(!rel("A.bookbook/images/x.png"))
        #expect(!rel("A.bookbook/pages/p.json"))
        #expect(!rel("A.bookbook/pages/book.json"))
        #expect(!rel("notes.txt"))
        #expect(!LibraryIndex.isRelevant(path: "/tmp/other/A.bookbook", root: root))
    }
}
