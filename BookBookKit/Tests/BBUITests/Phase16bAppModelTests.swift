import BBAI
import BBModel
import BBStore
import Foundation
import Testing
@testable import BBUI

/// Phase 16b `AppModel` fixes: #18, #72b, #72c, #42a (`undeliveredCount`), #3g, #34a.
@MainActor
struct Phase16bAppModelTests {
    let dir = FileManager.default.temporaryDirectory.appending(path: "bbui-16b-app-\(UUID().uuidString)")
    let suiteName = "bbui-tests-\(UUID().uuidString)"

    func makeApp() throws -> AppModel {
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return AppModel(providers: [:], libraryRoot: dir.appending(path: "Library", directoryHint: .isDirectory),
                        keychainService: "app.bookbook.tests-\(UUID())",
                        indexCacheURL: dir.appending(path: "library-index.json"), userDefaults: defaults,
                        thumbnails: ThumbnailCache(root: dir.appending(path: "Caches")),
                        appSupport: AppSupportFiles(folderURL: dir.appending(path: "AppSupport")))
    }

    func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func replayDropsTheConsistencyFixSource() throws {
        defer { tearDown() }
        let app = try makeApp()
        var intent = GenerationIntent(messageText: "fix the hat", provider: .openai, model: "gpt-image-2.5-sunburst",
                                      quality: .draft)
        intent.versionSource = .consistencyFix
        let replayed = app.replayed(intent)
        #expect(replayed.versionSource == nil)
        #expect(replayed.messageText == intent.messageText)
    }

    @Test func newBookRequestsAreExclusive() throws {
        defer { tearDown() }
        let app = try makeApp()
        app.newBookRequest = .blank
        app.newBookRequest = .fromStory
        #expect(app.newBookRequest == .fromStory)
        app.newBookRequest = .blank
        #expect(app.newBookRequest == .blank)
        app.newBookRequest = nil
        #expect(app.newBookRequest == nil)
    }

    @Test func pendingStoryImportIsDroppedWhenTheWindowClosesOrTheBookIsForgotten() async throws {
        defer { tearDown() }
        let app = try makeApp()
        await app.start()
        let closed = try await app.createBook(title: "Closed", thenImportStory: true)
        app.windowDidClose(closed.id)
        #expect(!app.takePendingStoryImport(for: closed.id))

        let forgotten = try await app.createBook(title: "Forgotten", thenImportStory: true)
        app.forgetBook(forgotten.id)
        #expect(!app.takePendingStoryImport(for: forgotten.id))
    }

    @Test func createBookFromSpecStillCreates() async throws {
        defer { tearDown() }
        let app = try makeApp()
        await app.start()
        var spec = NewBookSpec(title: "Off main")
        spec.importStoryAfter = true
        let entry = try await app.createBook(spec: spec)
        #expect(app.libraryEntries.contains { $0.id == entry.id })
        #expect(app.takePendingStoryImport(for: entry.id))
    }

    @Test func undeliveredCountFollowsTheQueue() async throws {
        defer { tearDown() }
        // A saved queue with one picture still waiting for its (now missing) book.
        let files = AppSupportFiles(folderURL: dir.appending(path: "AppSupport"))
        let content = Fixtures.book()
        let page = Fixtures.firstPage(content)
        let item = QueueItem(bookID: content.book.id, target: .pageBox(page, Fixtures.imageBox.id),
                             messageID: MessageID(), intent: Fixtures.provenance().intent)
        let delivery = GenerationDelivery(item: item, outcome: .failure(.cancelled))
        await QueueFileStore(files: files).save(PersistedQueue(
            entries: [], undelivered: [PersistedDelivery(token: UUID(), delivery: delivery)]))
        let app = try makeApp()
        #expect(app.queueSnapshot.undeliveredCount == 0)
        await app.queueOperationsSettled()
        // The book isn't in this library: dropped (bookGone), so the count settles at 0 and the
        // spool entry is gone from queue.json after quit's flush.
        await app.prepareForQuit()
        #expect(await app.queue.snapshot().undeliveredCount == 0)
        #expect(await QueueFileStore(files: files).load()?.undelivered.isEmpty == true)
    }
}
