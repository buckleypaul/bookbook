import BBModel
import Foundation
import Testing
@testable import BBStore

/// Phase 11: a region edit's mask and raw provider output are in use, not orphans.
@Suite struct RegionEditSweepTests {
    @Test func sweepKeepsMaskAndRawOutputImages() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "B.bookbook")
        var (content, fox) = try AssetStoreTests.withAsset()
        let store = BookStore(packageURL: url)
        try BookStore.create(content, at: url)
        let base = try await store.storeImage(Data([1]), contentType: "public.png")
        let composite = try await store.storeImage(Data([2]), contentType: "public.png")
        let mask = try await store.storeImage(Data([3]), contentType: "public.png")
        let raw = try await store.storeImage(Data([4]), contentType: "public.png")
        let orphan = try await store.storeImage(Data([5]), contentType: "public.png")

        let slot = fox.references[0]
        let size = PixelSize(width: 1, height: 1)
        let baseVersion = Version(image: base, pixelSize: size, source: .imported, createdAt: testNow)
        let intent = GenerationIntent(messageText: "make it yellow", refines: baseVersion.id, provider: .openai,
                                      model: "m", quality: .draft, regionMask: mask)
        let provenance = Provenance(provider: .openai, model: "m", quality: .draft, outputSize: size, promptSent: "p",
                                    styleRevision: 0, storyTextIncluded: false, intent: intent,
                                    maskSent: mask, rawOutput: raw, featherPixels: 8)
        let edit = Version(image: composite, pixelSize: size, source: .regionEdit, parent: baseVersion.id,
                           createdAt: testNow, provenance: provenance)
        content.sessions[slot.sessionID]?.versions = [baseVersion, edit]
        fox.references[0].chosen = edit.id
        content.assets[fox.id] = fox
        try await store.save(content, dirty: DirtySet(sessions: [slot.sessionID], assets: [fox.id]))

        let removed = try await store.sweepOrphanImages(referencedBy: content, minimumAge: 0,
                                                        now: Date().addingTimeInterval(10))
        #expect(removed == 1)
        for ref in [base, composite, mask, raw] { #expect(exists(store.imageURL(for: ref))) }
        #expect(!exists(store.imageURL(for: orphan)))
    }
}
