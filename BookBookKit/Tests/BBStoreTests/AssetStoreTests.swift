import BBModel
import Foundation
import Testing
@testable import BBStore

/// Phase 10: `assets/<id>.json` is created, journaled, deleted, and optional in older packages.
@Suite struct AssetStoreTests {
    static func withAsset() throws -> (BookContent, Asset) {
        var content = try sampleContent()
        var fox = Asset.makeNew(type: .character, name: "Fox")
        fox.description = "red fox"
        content.assets[fox.id] = fox
        for (sid, owner) in fox.ownedSessions { content.sessions[sid] = Session(id: sid, owner: owner) }
        return (content, fox)
    }

    @Test func createSaveReloadDelete() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "B.bookbook")
        var (content, fox) = try Self.withAsset()
        try BookStore.create(content, at: url)
        let file = url.appending(path: PackageCoding.assetPath(fox.id))
        #expect(exists(file))
        let store = BookStore(packageURL: url)
        #expect(try await store.load() == content)

        fox.description = "blue fox"
        content.assets[fox.id] = fox
        try await store.save(content, dirty: DirtySet(assets: [fox.id]))
        #expect(try await BookStore(packageURL: url).load().assets[fox.id]?.description == "blue fox")

        content.assets[fox.id] = nil
        try await store.save(content, dirty: DirtySet(deletedAssets: [fox.id]))
        #expect(!exists(file))
        #expect(try await BookStore(packageURL: url).load().assets.isEmpty)

        // Undo: accumulated delete-then-reinsert writes it back.
        content.assets[fox.id] = fox
        var dirty = DirtySet(deletedAssets: [fox.id])
        dirty.formUnion(DirtySet(assets: [fox.id]))
        #expect(dirty.assets == [fox.id] && dirty.deletedAssets.isEmpty)
        var reverse = DirtySet(assets: [fox.id])
        reverse.formUnion(DirtySet(deletedAssets: [fox.id]))
        #expect(reverse.assets.isEmpty && reverse.deletedAssets == [fox.id])
        try await store.save(content, dirty: dirty)
        #expect(exists(file))
    }

    @Test func olderPackageWithoutAssetsFolderLoadsAndSaves() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "B.bookbook")
        try BookStore.create(try sampleContent(), at: url)
        try FileManager.default.removeItem(at: url.appending(path: "assets"))
        let store = BookStore(packageURL: url)
        var content = try await store.load()
        #expect(content.assets.isEmpty)
        let pond = Asset.makeNew(type: .place, name: "Pond")
        content.assets[pond.id] = pond
        try await store.save(content, dirty: DirtySet(assets: [pond.id]))
        #expect(try await BookStore(packageURL: url).load().assets[pond.id] == pond)
    }

    @Test func sweepKeepsAssetSessionImages() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "B.bookbook")
        var (content, fox) = try Self.withAsset()
        let store = BookStore(packageURL: url)
        try BookStore.create(content, at: url)
        let ref = try await store.storeImage(Data([1, 2, 3]), contentType: "public.png")
        let slot = fox.references[0]
        let version = Version(image: ref, pixelSize: PixelSize(width: 1, height: 1), source: .imported, createdAt: testNow)
        content.sessions[slot.sessionID]?.versions.append(version)
        fox.references[0].chosen = version.id
        content.assets[fox.id] = fox
        try await store.save(content, dirty: DirtySet(sessions: [slot.sessionID], assets: [fox.id]))
        let removed = try await store.sweepOrphanImages(referencedBy: content, minimumAge: 0, now: Date().addingTimeInterval(10))
        #expect(removed == 0)
        #expect(exists(store.imageURL(for: ref)))
    }
}
