import BBModel
import Foundation
import Testing
@testable import BBStore

let testNow = Date(timeIntervalSince1970: 1_700_000_000)

func makeTempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "bbstore-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func sampleContent(title: String = "Test") throws -> BookContent {
    BookContent.makeNew(title: title, storyTemplate: try Presets.storyTemplate(),
                        coverTemplate: try Presets.coverTemplate(), storyPageCount: 2, now: testNow)
}

func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }

@Suite struct BookStoreTests {
    @Test func createLoadRoundTrip() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "B.bookbook")
        let content = try sampleContent()
        try BookStore.create(content, at: url)
        #expect(exists(url.appending(path: "book.json")))
        #expect(exists(url.appending(path: "style.json")))
        #expect(exists(url.appending(path: "images")))
        let loaded = try await BookStore(packageURL: url).load()
        #expect(loaded == content)
        #expect(throws: StoreError.self) { try BookStore.create(content, at: url) }
    }

    @Test func loadMissingIsNotFound() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        await #expect(throws: StoreError.notFound("x.bookbook")) {
            try await BookStore(packageURL: dir.appending(path: "x.bookbook")).load()
        }
    }

    @Test func schemaTooNew() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "B.bookbook")
        try BookStore.create(try sampleContent(), at: url)
        try Data(#"{"schemaVersion": 99, "future": true}"#.utf8).write(to: url.appending(path: "book.json"))
        await #expect(throws: StoreError.schemaTooNew(99)) { try await BookStore(packageURL: url).load() }
    }

    @Test func saveWritesOnlyDirtyEntitiesAndDeletes() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "B.bookbook")
        var content = try sampleContent()
        try BookStore.create(content, at: url)
        let store = BookStore(packageURL: url)

        let editedID = content.book.pageOrder[0]
        let untouchedID = content.book.pageOrder[1]
        let untouched = url.appending(path: "pages/\(untouchedID.rawValue.uuidString).json")
        let untouchedBefore = try Data(contentsOf: untouched)
        let untouchedMTime = try FileManager.default.attributesOfItem(atPath: untouched.path(percentEncoded: false))[.modificationDate] as? Date

        try await Task.sleep(for: .milliseconds(20))
        let boxID = content.pages[editedID]!.text.keys.first ?? content.template(for: content.pages[editedID]!)!.textBoxes[0].id
        content.pages[editedID]!.text[boxID] = RichText(plain: "Once upon a time")
        try await store.save(content, dirty: DirtySet(pages: [editedID]))

        #expect(try Data(contentsOf: untouched) == untouchedBefore)
        #expect(try FileManager.default.attributesOfItem(atPath: untouched.path(percentEncoded: false))[.modificationDate] as? Date == untouchedMTime)
        #expect(try await store.load() == content)
        let journalLeft = (try? FileManager.default.contentsOfDirectory(atPath: url.appending(path: ".journal").path(percentEncoded: false))) ?? []
        #expect(journalLeft.isEmpty)

        // Deleting a page removes its file.
        content.pages[untouchedID] = nil
        content.book.pageOrder.removeAll { $0 == untouchedID }
        try await store.save(content, dirty: DirtySet(book: true, deletedPages: [untouchedID]))
        #expect(!exists(untouched))
        #expect(try await store.load() == content)
    }

    @Test func committedJournalRollsForward() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "B.bookbook")
        var content = try sampleContent()
        try BookStore.create(content, at: url)
        let pageID = content.book.pageOrder[0]
        let removedID = content.book.pageOrder[1]
        let boxID = content.template(for: content.pages[pageID]!)!.textBoxes[0].id
        content.pages[pageID]!.text[boxID] = RichText(plain: "staged")
        let files = try PackageCoding.files(for: content, dirty: DirtySet(pages: [pageID]))
        // Crash after COMMIT, before any rename.
        try Journal(packageURL: url).run(files: files, deletions: [PackageCoding.pagePath(removedID)], apply: false)

        let loaded = try await BookStore(packageURL: url).load()
        #expect(loaded.pages[pageID]?.text[boxID]?.plainText == "staged")
        #expect(loaded.pages[removedID] == nil)
        #expect(!exists(url.appending(path: ".journal")))
    }

    /// Writes a committed hand-made transaction with the given manifest paths.
    private func craftJournal(at url: URL, targets: [String], deletions: [String], txid: String = UUID().uuidString) throws {
        let tx = url.appending(path: ".journal/\(txid)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tx.appending(path: "staged"), withIntermediateDirectories: true)
        for t in targets {
            let staged = tx.appending(path: "staged").appending(path: t)
            try FileManager.default.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("evil".utf8).write(to: staged)
        }
        try PackageCoding.encoder().encode(Journal.Manifest(targets: targets, deletions: deletions))
            .write(to: tx.appending(path: "manifest.json"))
        try Data().write(to: tx.appending(path: "COMMIT"))
    }

    @Test(arguments: [
        (["../outside.json"], [String]()),
        ([String](), ["../victim"]),
        (["/tmp/abs.json"], [String]()),
        (["pages/../../outside.json"], [String]()),
        ([String](), ["images/x.png"]),
        (["book.json", "../outside.json"], [String]()),
    ])
    func craftedJournalIsDiscardedWithoutTouchingOutside(targets: [String], deletions: [String]) async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "B.bookbook")
        let content = try sampleContent()
        try BookStore.create(content, at: url)
        let victim = dir.appending(path: "victim")
        try Data("keep".utf8).write(to: victim)
        try craftJournal(at: url, targets: targets, deletions: deletions)

        let loaded = try await BookStore(packageURL: url).load()
        #expect(loaded == content) // nothing partly applied, not even the valid book.json entry
        #expect(try Data(contentsOf: victim) == Data("keep".utf8))
        #expect(!exists(dir.appending(path: "outside.json")))
        #expect(!exists(url.appending(path: ".journal")))
    }

    @Test func journalWithBadTxidOrSymlinkedDirIsDiscarded() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "B.bookbook")
        let content = try sampleContent()
        try BookStore.create(content, at: url)
        let pageFile = "pages/\(UUID().uuidString).json"
        try craftJournal(at: url, targets: [pageFile], deletions: [], txid: "not-a-uuid")
        // pages/ replaced by a symlink to an outside folder.
        let outside = dir.appending(path: "outside", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.removeItem(at: url.appending(path: "pages"))
        try FileManager.default.createSymbolicLink(at: url.appending(path: "pages"), withDestinationURL: outside)
        try craftJournal(at: url, targets: [pageFile], deletions: [])

        _ = try? await BookStore(packageURL: url).load() // pages symlink may read as empty
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path(percentEncoded: false)).isEmpty)
        #expect(!exists(url.appending(path: ".journal")))
    }

    @Test func uncommittedJournalIsDiscarded() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "B.bookbook")
        var content = try sampleContent()
        try BookStore.create(content, at: url)
        let original = content
        let pageID = content.book.pageOrder[0]
        let boxID = content.template(for: content.pages[pageID]!)!.textBoxes[0].id
        content.pages[pageID]!.text[boxID] = RichText(plain: "never committed")
        let files = try PackageCoding.files(for: content, dirty: DirtySet(pages: [pageID]))
        try Journal(packageURL: url).run(files: files, deletions: [], commit: false)

        let loaded = try await BookStore(packageURL: url).load()
        #expect(loaded == original)
        #expect(!exists(url.appending(path: ".journal")))
    }

    @Test func storeImageIsContentAddressedAndIdempotent() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "B.bookbook")
        try BookStore.create(try sampleContent(), at: url)
        let store = BookStore(packageURL: url)
        let bytes = Data("not really a png".utf8)
        let a = try await store.storeImage(bytes, contentType: "public.png")
        let b = try await store.storeImage(bytes, contentType: "public.png")
        #expect(a == b)
        #expect(a.sha256.count == 64)
        #expect(store.imageURL(for: a).lastPathComponent == "\(a.sha256).png")
        #expect(try Data(contentsOf: store.imageURL(for: a)) == bytes)
        let files = try FileManager.default.contentsOfDirectory(atPath: url.appending(path: "images").path(percentEncoded: false))
        #expect(files == ["\(a.sha256).png"])
        let other = try await store.storeImage(Data("other".utf8), contentType: "public.jpeg")
        #expect(other.sha256 != a.sha256)
        #expect(other.fileName.hasSuffix(".jpg"))
    }

    @Test func storeImageKnownHash() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "B.bookbook")
        try BookStore.create(try sampleContent(), at: url)
        let ref = try await BookStore(packageURL: url).storeImage(Data("abc".utf8), contentType: "public.png")
        #expect(ref.sha256 == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func debounceCoalescesAndKeepsHighestGeneration() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "B.bookbook")
        let original = try sampleContent()
        try BookStore.create(original, at: url)
        let store = BookStore(packageURL: url, debounce: .milliseconds(150))

        let p0 = original.book.pageOrder[0]
        let p1 = original.book.pageOrder[1]
        let box = original.template(for: original.pages[p0]!)!.textBoxes[0].id
        var gen1 = original
        gen1.pages[p0]!.text[box] = RichText(plain: "gen1")
        var gen3 = gen1
        gen3.pages[p0]!.text[box] = RichText(plain: "gen3")
        gen3.pages[p1]!.isDone = true
        var gen2stale = gen1
        gen2stale.pages[p0]!.text[box] = RichText(plain: "gen2 stale")

        await store.scheduleSave(gen1, dirty: DirtySet(pages: [p0]), generation: 1)
        await store.scheduleSave(gen3, dirty: DirtySet(pages: [p1]), generation: 3)
        await store.scheduleSave(gen2stale, dirty: DirtySet(pages: [p0]), generation: 2)

        // Nothing is written before the debounce elapses.
        #expect(try await store.load() == original)
        try await Task.sleep(for: .milliseconds(600))
        #expect(try await store.load() == gen3)
        try await store.flush() // nothing pending: no-op
        #expect(try await store.load() == gen3)
    }

    @Test func datesRoundTripExactly() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "B.bookbook")
        var content = try sampleContent()
        try BookStore.create(content, at: url)
        let store = BookStore(packageURL: url)
        for _ in 0..<50 {
            content.book.modifiedAt = Date()
            try await store.save(content, dirty: DirtySet(book: true))
            #expect(try await store.load() == content)
        }
        // Dates without a fraction (older files) still decode.
        let d = try PackageCoding.decoder().decode(Date.self, from: Data(#""2023-11-14T22:13:20Z""#.utf8))
        #expect(d == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test func flushWritesImmediately() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "B.bookbook")
        var content = try sampleContent()
        try BookStore.create(content, at: url)
        let store = BookStore(packageURL: url) // 1 s debounce
        content.book.title = "Renamed"
        await store.scheduleSave(content, dirty: DirtySet(book: true), generation: 1)
        try await store.flush()
        #expect(try await store.load().book.title == "Renamed")
    }
}
