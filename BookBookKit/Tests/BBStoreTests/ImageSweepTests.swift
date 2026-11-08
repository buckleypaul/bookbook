import BBModel
import Foundation
import Testing
@testable import BBStore

/// Orphan image sweep at open (A §5.2): only unreferenced files older than 24 h go.
@Suite(.cheapSync) struct ImageSweepTests {
    private func age(_ url: URL, by seconds: TimeInterval) throws {
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -seconds)],
                                              ofItemAtPath: url.path(percentEncoded: false))
    }

    private func version(_ ref: ImageRef, sent: [ImageRef] = [], omitted: [ImageRef] = []) -> BBModel.Version {
        let provenance = sent.isEmpty && omitted.isEmpty ? nil : Provenance(
            provider: .openai, model: "m", quality: .draft, outputSize: PixelSize(width: 1, height: 1), promptSent: "",
            referencesSent: sent.map { SentReference(image: $0, role: "base", label: "b") },
            referencesOmitted: omitted.map { SentReference(image: $0, role: "asset", label: "a") },
            styleRevision: 0, storyTextIncluded: false,
            intent: GenerationIntent(messageText: "", provider: .openai, model: "m", quality: .draft))
        return BBModel.Version(image: ref, pixelSize: PixelSize(width: 1, height: 1), source: .generated,
                               createdAt: testNow, provenance: provenance)
    }

    @Test func sweepAtOpenRemovesOnlyOldOrphans() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "B.bookbook")
        var content = try sampleContent()
        try BookStore.create(content, at: url)
        let store = BookStore(packageURL: url)

        func put(_ name: String) async throws -> (ImageRef, URL) {
            let ref = try await store.storeImage(Data(name.utf8), contentType: "public.png")
            return (ref, store.imageURL(for: ref))
        }
        let (versionRef, versionURL) = try await put("version")
        let (sentRef, sentURL) = try await put("sent")
        let (omittedRef, omittedURL) = try await put("omitted")
        let (styleRef, styleURL) = try await put("style")
        let (_, oldOrphan) = try await put("old orphan")
        let (_, youngOrphan) = try await put("young orphan")
        let jpegOrphan = try await store.imageURL(for: store.storeImage(Data("jpeg".utf8), contentType: "public.jpeg"))
        let debris = url.appending(path: "images/.tmp-\(UUID().uuidString)")
        try Data("half".utf8).write(to: debris)

        let pageID = content.book.pageOrder[0]
        let session = Session(owner: .pageBox(pageID, BoxID()),
                              versions: [version(versionRef, sent: [sentRef], omitted: [omittedRef])])
        content.sessions[session.id] = session
        content.style.styleReferences = [styleRef]
        try await store.save(content, dirty: DirtySet(style: true, sessions: [session.id]))

        for file in [versionURL, sentURL, omittedURL, styleURL, oldOrphan, jpegOrphan, debris] {
            try age(file, by: 90_000)
        }
        try age(youngOrphan, by: 3_600)
        // Package-root files that are not content.
        try Data("{}".utf8).write(to: url.appending(path: ".lock"))
        try Data("png".utf8).write(to: url.appending(path: "thumbnail.png"))
        try age(url.appending(path: "thumbnail.png"), by: 90_000)

        let loaded = try await BookStore(packageURL: url).load()
        #expect(loaded == content)
        for kept in [versionURL, sentURL, omittedURL, styleURL, youngOrphan] { #expect(exists(kept), "\(kept.lastPathComponent)") }
        for gone in [oldOrphan, jpegOrphan, debris] { #expect(!exists(gone), "\(gone.lastPathComponent)") }
        #expect(exists(url.appending(path: ".lock")))
        #expect(exists(url.appending(path: "thumbnail.png")))
    }

    @Test func sweepHonoursMinimumAgeAndReturnsCount() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "B.bookbook")
        let content = try sampleContent()
        try BookStore.create(content, at: url)
        let store = BookStore(packageURL: url)
        let a = try await store.imageURL(for: store.storeImage(Data("a".utf8), contentType: "public.png"))
        _ = try await store.storeImage(Data("b".utf8), contentType: "public.png")
        let now = Date()
        #expect(try await store.sweepOrphanImages(referencedBy: content, now: now) == 0)
        #expect(try await store.sweepOrphanImages(referencedBy: content, minimumAge: 60, now: now.addingTimeInterval(120)) == 2)
        #expect(!exists(a))
    }

    @Test func sweepRefusesSymlinkedImagesFolder() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "B.bookbook")
        let content = try sampleContent()
        try BookStore.create(content, at: url)
        let outside = dir.appending(path: "outside", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let victim = outside.appending(path: "victim.png")
        try Data("keep".utf8).write(to: victim)
        try age(victim, by: 200_000)
        try FileManager.default.removeItem(at: url.appending(path: "images"))
        try FileManager.default.createSymbolicLink(at: url.appending(path: "images"), withDestinationURL: outside)
        await #expect(throws: StoreError.self) {
            try await BookStore(packageURL: url).sweepOrphanImages(referencedBy: content, minimumAge: 0)
        }
        #expect(exists(victim))
    }
}
