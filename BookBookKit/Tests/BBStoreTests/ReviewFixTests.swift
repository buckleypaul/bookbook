import BBModel
import Foundation
import Testing
@testable import BBStore

private final class ResultLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [StoreError?] = []
    func add(_ e: StoreError?) { lock.lock(); items.append(e); lock.unlock() }
    var all: [StoreError?] { lock.lock(); defer { lock.unlock() }; return items }
}

@Suite struct ReviewFixTests {
    @Test func autosaveHandlerReportsSuccessAndFailureAndKeepsPending() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "B.bookbook")
        var content = try sampleContent()
        try BookStore.create(content, at: url)
        let store = BookStore(packageURL: url, debounce: .milliseconds(50))
        let log = ResultLog()
        await store.setAutosaveResultHandler { log.add($0) }

        content.book.title = "One"
        await store.scheduleSave(content, dirty: DirtySet(book: true), generation: 1)
        try await waitUntil { log.all.count >= 1 }
        #expect(log.all == [nil])

        // Make saves fail: a plain file where the journal folder must go (it is gone after a save).
        try? FileManager.default.removeItem(at: url.appending(path: ".journal"))
        try Data().write(to: url.appending(path: ".journal"))
        content.book.title = "Two"
        await store.scheduleSave(content, dirty: DirtySet(book: true), generation: 2)
        try await waitUntil { log.all.count >= 2 }
        try #require(log.all.count == 2)
        #expect(log.all[1] != nil)

        // Pending snapshot is kept: flush fails too, then succeeds once the obstacle is gone.
        await #expect(throws: StoreError.self) { try await store.flush() }
        #expect(log.all.count == 3)
        try FileManager.default.removeItem(at: url.appending(path: ".journal"))
        try await store.flush()
        #expect(log.all.count == 4 && log.all[3] == nil)
        #expect(try await store.load().book.title == "Two")
    }

    @Test func scheduledSaveCompletesAfterStoreReferenceIsDropped() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "B.bookbook")
        var content = try sampleContent()
        try BookStore.create(content, at: url)
        do {
            let store = BookStore(packageURL: url, debounce: .milliseconds(100))
            content.book.title = "Dropped"
            await store.scheduleSave(content, dirty: DirtySet(book: true), generation: 1)
        }
        // Poll book.json directly: opening the book while the save is in flight would race its journal.
        try await waitUntil {
            (try? PackageCoding.decoder().decode(Book.self, from: Data(contentsOf: url.appending(path: "book.json"))))?.title == "Dropped"
        }
        #expect(try await BookStore(packageURL: url).load().book.title == "Dropped")
    }

    @Test func invalidImageRefsAreDroppedOnLoad() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "B.bookbook")
        var content = try sampleContent()
        let good = ImageRef(sha256: String(repeating: "a", count: 64), contentType: "public.png")
        let evil = ImageRef(sha256: "../../../etc/passwd", contentType: "public.png")
        let upper = ImageRef(sha256: String(repeating: "A", count: 64), contentType: "public.png")
        let badType = ImageRef(sha256: String(repeating: "b", count: 64), contentType: "com.evil")
        content.style.styleReferences = [good, evil]
        let sid = try #require(content.sessions.keys.first)
        func version(_ ref: ImageRef) -> BBModel.Version {
            Version(image: ref, pixelSize: PixelSize(width: 1, height: 1), source: .imported, createdAt: testNow)
        }
        var withProv = version(good)
        withProv.provenance = Provenance(
            provider: .openai, model: "m", quality: .draft, outputSize: PixelSize(width: 1, height: 1), promptSent: "p",
            referencesSent: [SentReference(image: good, role: "r", label: "l"), SentReference(image: evil, role: "r", label: "l")],
            referencesOmitted: [SentReference(image: badType, role: "r", label: "l")], styleRevision: 0,
            storyTextIncluded: false,
            intent: GenerationIntent(messageText: "", provider: .openai, model: "m", quality: .draft))
        content.sessions[sid]!.versions = [version(evil), version(upper), version(badType), withProv]
        // Write without going through storeImage; BookStore.create encodes whatever it is given.
        try BookStore.create(content, at: url)

        let store = BookStore(packageURL: url)
        let loaded = try await store.load()
        #expect(loaded.style.styleReferences == [good])
        let versions = try #require(loaded.sessions[sid]?.versions)
        #expect(versions.count == 1)
        #expect(versions[0].provenance?.referencesSent.map(\.image) == [good])
        #expect(versions[0].provenance?.referencesOmitted.isEmpty == true)

        // imageURL never leaves images/.
        let escaped = store.imageURL(for: evil)
        #expect(escaped.deletingLastPathComponent().lastPathComponent == "images")
        #expect(!exists(escaped))
        #expect(store.imageURL(for: good).lastPathComponent == "\(good.sha256).png")
        await #expect(throws: StoreError.self) { try await store.storeImage(Data("x".utf8), contentType: "com.evil") }
    }

    @Test func storeImageRefusesSymlinkedImagesFolder() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "B.bookbook")
        try BookStore.create(try sampleContent(), at: url)
        let outside = dir.appending(path: "outside", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.removeItem(at: url.appending(path: "images"))
        try FileManager.default.createSymbolicLink(at: url.appending(path: "images"), withDestinationURL: outside)
        await #expect(throws: StoreError.self) {
            try await BookStore(packageURL: url).storeImage(Data("x".utf8), contentType: "public.png")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path(percentEncoded: false)).isEmpty)
    }

    @Test func committedTransactionsReplayOldestFirst() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "B.bookbook")
        var content = try sampleContent()
        try BookStore.create(content, at: url)

        func craft(title: String, txid: String) throws {
            content.book.title = title
            let data = try PackageCoding.encode(content.book)
            let tx = url.appending(path: ".journal/\(txid)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: tx.appending(path: "staged"), withIntermediateDirectories: true)
            try data.write(to: tx.appending(path: "staged/book.json"))
            try PackageCoding.encoder().encode(Journal.Manifest(targets: ["book.json"], deletions: []))
                .write(to: tx.appending(path: "manifest.json"))
            try Data().write(to: tx.appending(path: "COMMIT"))
        }
        // The older txid has the larger UUID, so UUID-only ordering would apply it last.
        try craft(title: "newer", txid: "00000000000000000002-00000000-0000-0000-0000-000000000000")
        try craft(title: "older", txid: "00000000000000000001-FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")
        #expect(try await BookStore(packageURL: url).load().book.title == "newer")
    }

    @Test func newTxidsSortByCreationOrder() {
        let ids = (0..<20).map { _ in Journal.newTxid() }
        #expect(ids == ids.sorted())
    }
}

/// Polls `condition` every 20 ms for up to `timeout`. Debounced saves can run late when the
/// whole test target runs in parallel, so fixed sleeps are flaky.
private func waitUntil(timeout: Duration = .seconds(10), _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition(), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(20))
    }
}
