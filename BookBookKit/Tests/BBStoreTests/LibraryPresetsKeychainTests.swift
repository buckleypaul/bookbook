import BBModel
import Foundation
import Testing
@testable import BBStore

@Suite struct LibraryTests {
    @Test func createAndScan() async throws {
        let root = try makeTempDir().appending(path: "Library", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let lib = Library(root: root)
        #expect(lib.scan().isEmpty)

        let a = try lib.createBook(title: "Fox/Tales: One", now: Date(timeIntervalSince1970: 1_700_000_000))
        let b = try lib.createBook(title: "Fox/Tales: One", now: Date(timeIntervalSince1970: 1_700_000_100))
        let c = try lib.createBook(title: "Fox/Tales: One", now: Date(timeIntervalSince1970: 1_700_000_050))
        #expect(a.url.lastPathComponent == "Fox-Tales- One.bookbook")
        #expect(b.url.lastPathComponent == "Fox-Tales- One 2.bookbook")
        #expect(c.url.lastPathComponent == "Fox-Tales- One 3.bookbook")

        // An unreadable package and a stray file are skipped.
        try FileManager.default.createDirectory(at: root.appending(path: "Broken.bookbook"), withIntermediateDirectories: true)
        try Data().write(to: root.appending(path: "notes.txt"))

        let entries = lib.scan()
        #expect(entries.map(\.id) == [b.id, c.id, a.id])
        #expect(entries.allSatisfy { $0.title == "Fox/Tales: One" })

        let loaded = try await BookStore(packageURL: a.url).load()
        #expect(loaded.book.pageOrder.count == 1)
        #expect(loaded.coverPage != nil)
    }
}

@Suite struct PresetsTests {
    @Test func templatesDecodeWithFixedIDs() throws {
        let all = try Presets.templates()
        #expect(all.count == 10)
        let story = try Presets.storyTemplate()
        let cover = try Presets.coverTemplate()
        #expect(story.id == Presets.storyTemplateID)
        #expect(cover.id == Presets.coverTemplateID)
        #expect(story.name == "Image above text")
        #expect(story.kind == .single)
        #expect(story.imageBoxes.count == 1)
        #expect(story.textBoxes.count == 1)
        #expect(cover.kind == .cover)
        #expect(cover.imageBoxes.count == 1)
        #expect(cover.textBoxes.first?.role == .title)
        // Stable across loads.
        #expect(try Presets.templates() == all)
    }

    @Test func storyBoxesSitInsideMargins() throws {
        let story = try Presets.storyTemplate()
        for box in story.boxes {
            #expect(box.frame.x >= 36.0 / 612 - 0.001)
            #expect(box.frame.maxX <= 1 - 36.0 / 612 + 0.001)
            #expect(box.frame.y >= 36.0 / 792 - 0.001)
            #expect(box.frame.maxY <= 1 - 36.0 / 792 + 0.001)
        }
    }

    @Test func boxContentKindEncodingMatchesSynthesizedCodable() throws {
        let data = try JSONEncoder().encode(BoxContentKind.text(TextBoxStyle(padding: 0)))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let text = try #require(json["text"] as? [String: Any])
        #expect(text["_0"] != nil)
        let image = try JSONEncoder().encode(BoxContentKind.image)
        #expect(try JSONDecoder().decode(BoxContentKind.self, from: image) == .image)
    }
}

@Suite struct KeychainStoreTests {
    @Test func saveReadHasDelete() throws {
        let store = KeychainStore(service: "app.bookbook.api-key.tests-\(UUID().uuidString)")
        let value = "test-value-" + UUID().uuidString
        let key = try #require(APIKey(value))
        defer { try? store.delete(.openai); try? store.delete(.gemini) }

        #expect(!store.hasKey(.openai))
        #expect(store.read(.openai) == nil)
        try store.delete(.openai) // not-found is fine

        try store.save(key, for: .openai)
        #expect(store.hasKey(.openai))
        #expect(!store.hasKey(.gemini))
        #expect(store.read(.openai) == key)

        let replacement = try #require(APIKey("test-value-" + UUID().uuidString))
        try store.save(replacement, for: .openai)
        #expect(store.read(.openai) == replacement)

        try store.delete(.openai)
        #expect(!store.hasKey(.openai))
        #expect(store.read(.openai) == nil)
    }
}
