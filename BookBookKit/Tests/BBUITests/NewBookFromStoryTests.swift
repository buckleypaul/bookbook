import BBLayout
import BBModel
import BBStore
import Foundation
import Testing
@testable import BBUI

/// File ▸ New Book from Story… (PD §8.5): the new book opens with the import pending, and the
/// import lands in it as one undo step.
@MainActor
struct NewBookFromStoryTests {
    @Test func createBook_thenImportStory_flagsOnce_andImportMatches() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "bbui-story-\(UUID().uuidString)")
        let suiteName = "bbui-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: dir)
        }
        let app = AppModel(providers: [:], libraryRoot: dir.appending(path: "Library", directoryHint: .isDirectory),
                           keychainService: "app.bookbook.tests-\(UUID())",
                           indexCacheURL: dir.appending(path: "library-index.json"), userDefaults: defaults,
                           thumbnails: ThumbnailCache(root: dir.appending(path: "Caches")),
                           appSupport: AppSupportFiles(folderURL: dir.appending(path: "AppSupport")))
        await app.start()

        let plain = try await app.createBook(title: "Plain")
        #expect(!app.takePendingStoryImport(for: plain.id))

        let entry = try await app.createBook(title: "Story", thenImportStory: true)
        #expect(app.libraryEntries.contains { $0.id == entry.id })
        #expect(app.takePendingStoryImport(for: entry.id))
        #expect(!app.takePendingStoryImport(for: entry.id), "the sheet is presented once")

        let document = try await app.openBook(entry.id)
        let pages = PagesController(document: document)
        let undo = UndoManager()
        document.undoManager = undo
        let before = document.content.book.pageOrder.count

        let split = StoryTextImporter.split(StoryTextImporter.richText(fromPlain: "One.\n\nTwo.\n\nThree."),
                                            rule: .blankLines)
        #expect(split.count == 3)
        pages.importStory(split, templateID: Presets.storyTemplateID)

        let order = document.content.book.pageOrder
        #expect(order.count == before + 3)
        let texts = order.suffix(3).compactMap { id in
            document.content.pages[id]?.text.values.first?.plainText
        }
        #expect(texts == split.map(\.plainText))
        undo.undo()
        #expect(document.content.book.pageOrder.count == before, "one undo step")
        await app.closeBook(entry.id)
        await app.index.stopWatching()
    }
}
