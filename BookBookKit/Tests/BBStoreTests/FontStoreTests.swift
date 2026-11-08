import BBModel
import Foundation
import Testing
@testable import BBStore

/// Imported fonts in `fonts/` (A §5.1, §8.3).
@Suite(.cheapSync) struct FontStoreTests {
    private func makeBook() throws -> (dir: URL, url: URL, content: BookContent) {
        let dir = try makeTempDir()
        let url = dir.appending(path: "B.bookbook")
        let content = try sampleContent()
        try BookStore.create(content, at: url)
        return (dir, url, content)
    }

    @Test func storeAndListRoundTrip() async throws {
        let (dir, url, _) = try makeBook()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = BookStore(packageURL: url)
        #expect(store.fontFileURLs().isEmpty)
        let bytes = Data("font-a".utf8)
        let a = try await store.storeFont(bytes, fileExtension: "TTF")
        let b = try await store.storeFont(Data("font-b".utf8), fileExtension: "otf")
        #expect(a.pathExtension == "ttf")
        #expect(a.deletingLastPathComponent().lastPathComponent == "fonts")
        #expect(try Data(contentsOf: a) == bytes)
        #expect(store.fontFileURLs().map(\.lastPathComponent) == [a, b].map(\.lastPathComponent).sorted())
    }

    @Test func sameBytesDedupeWithoutRewrite() async throws {
        let (dir, url, _) = try makeBook()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = BookStore(packageURL: url)
        let a = try await store.storeFont(Data("x".utf8), fileExtension: "ttf")
        let old = Date(timeIntervalSinceNow: -5_000)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: a.path(percentEncoded: false))
        let b = try await store.storeFont(Data("x".utf8), fileExtension: "ttf")
        #expect(a == b)
        #expect(store.fontFileURLs().count == 1)
        let attrs = try FileManager.default.attributesOfItem(atPath: a.path(percentEncoded: false))
        #expect(attrs[.modificationDate] as? Date == old)
    }

    @Test func badExtensionThrowsIO() async throws {
        let (dir, url, _) = try makeBook()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = BookStore(packageURL: url)
        for ext in ["woff", "", "../ttf", "png"] {
            await #expect(throws: StoreError.self) { try await store.storeFont(Data("x".utf8), fileExtension: ext) }
        }
        #expect(store.fontFileURLs().isEmpty)
    }

    @Test func readOnlyRefuses() async throws {
        let (dir, url, _) = try makeBook()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = BookStore(packageURL: url)
        await store.setReadOnly()
        await #expect(throws: StoreError.readOnly) { try await store.storeFont(Data("x".utf8), fileExtension: "ttf") }
        #expect(store.fontFileURLs().isEmpty)
    }

    @Test func missingFolderIsEmpty() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(BookStore(packageURL: dir.appending(path: "None.bookbook")).fontFileURLs().isEmpty)
    }

    @Test func fontsSurviveOrphanSweep() async throws {
        let (dir, url, content) = try makeBook()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = BookStore(packageURL: url)
        let f = try await store.storeFont(Data("keep".utf8), fileExtension: "ttc")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -500_000)],
                                              ofItemAtPath: f.path(percentEncoded: false))
        _ = try await store.sweepOrphanImages(referencedBy: content, minimumAge: 0)
        #expect(store.fontFileURLs().map(\.lastPathComponent) == [f.lastPathComponent])
    }
}
