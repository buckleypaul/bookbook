import BBModel
import Foundation
import Testing
@testable import BBStore

/// An asset's optional reference photo (PD §8.3) on disk: saved and reopened, kept by the orphan
/// sweep, carried by Import from Book, and dropped on open when its ref is invalid.
@Suite struct AssetReferencePhotoStoreTests {
    @Test func sweepReferencesTheAssetsReferencePhoto() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "B.bookbook")
        var (content, fox) = try AssetStoreTests.withAsset()
        try BookStore.create(content, at: url)
        let store = BookStore(packageURL: url)
        let photo = try await store.storeImage(Data("photo".utf8), contentType: "public.jpeg")
        #expect(!ImageSweep.referencedFileNames(in: content).contains(photo.fileName))

        fox.referencePhoto = AssetReferencePhoto(image: photo, pixelSize: PixelSize(width: 4, height: 3),
                                                 depictsRealPerson: true)
        content.assets[fox.id] = fox
        #expect(ImageSweep.referencedFileNames(in: content).contains(photo.fileName))

        try await store.save(content, dirty: DirtySet(assets: [fox.id]))
        let removed = try await store.sweepOrphanImages(referencedBy: content, minimumAge: 0,
                                                        now: Date().addingTimeInterval(10))
        #expect(removed == 0)
        #expect(exists(store.imageURL(for: photo)))
    }

    @Test func saveAndReopenKeepsTheReferencePhoto() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "B.bookbook")
        var (content, fox) = try AssetStoreTests.withAsset()
        try BookStore.create(content, at: url)
        let store = BookStore(packageURL: url)
        let ref = try await store.storeImage(Data("photo".utf8), contentType: "public.jpeg")
        let photo = AssetReferencePhoto(image: ref, pixelSize: PixelSize(width: 1536, height: 1024),
                                        depictsRealPerson: true)
        fox.referencePhoto = photo
        content.assets[fox.id] = fox
        try await store.save(content, dirty: DirtySet(assets: [fox.id]))

        let loaded = try await BookStore(packageURL: url).load()
        #expect(loaded.assets[fox.id]?.referencePhoto == photo)
        #expect(loaded == content)

        // Removing it is saved too (encodeIfPresent: no key at all).
        fox.referencePhoto = nil
        content.assets[fox.id] = fox
        try await store.save(content, dirty: DirtySet(assets: [fox.id]))
        let json = try String(decoding: Data(contentsOf: url.appending(path: PackageCoding.assetPath(fox.id))),
                              as: UTF8.self)
        #expect(!json.contains("referencePhoto"))
        #expect(try await BookStore(packageURL: url).load().assets[fox.id]?.referencePhoto == nil)
    }

    @Test func invalidReferencePhotoRefIsDroppedOnOpen() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "B.bookbook")
        var (content, fox) = try AssetStoreTests.withAsset()
        var owl = Asset.makeNew(type: .character, name: "Owl")
        content.sessions[owl.sessionID] = Session(id: owl.sessionID, owner: owl.owner)
        // An unsupported content type, and a sha256 that isn't 64 lowercase hex digits.
        fox.referencePhoto = AssetReferencePhoto(
            image: ImageRef(sha256: String(repeating: "ab", count: 32), contentType: "com.compuserve.gif"),
            depictsRealPerson: false)
        owl.referencePhoto = AssetReferencePhoto(
            image: ImageRef(sha256: "../../escape", contentType: "public.png"), depictsRealPerson: false)
        content.assets[fox.id] = fox
        content.assets[owl.id] = owl
        try BookStore.create(content, at: url)

        let loaded = try await BookStore(packageURL: url).load()
        let loadedFox = try #require(loaded.assets[fox.id])
        let loadedOwl = try #require(loaded.assets[owl.id])
        #expect(loadedFox.referencePhoto == nil)
        #expect(loadedOwl.referencePhoto == nil)
        // The rest of the asset still loads.
        #expect(loadedFox.name == "Fox" && loadedFox.description == "red fox")
        #expect(loadedOwl.name == "Owl")
    }

    @Test func importerCarriesTheReferencePhotoAndCopiesItsImage() async throws {
        var src = try DiskBook.make(title: "Src")
        let dst = try DiskBook.make(title: "Dst")
        defer { try? FileManager.default.removeItem(at: src.dir); try? FileManager.default.removeItem(at: dst.dir) }
        var pip = try await src.addAsset(name: "Pip", primaryBytes: "pip-front")
        let ref = try await src.store.storeImage(Data("pip-photo".utf8), contentType: "public.jpeg")
        let photo = AssetReferencePhoto(image: ref, pixelSize: PixelSize(width: 8, height: 6), depictsRealPerson: true)
        pip.referencePhoto = photo
        src.content.assets[pip.id] = pip

        let imp = try BookImporter.build(source: src.content, target: dst.content,
                                         selection: BookImportSelection(assets: [pip.id]))
        let asset = try #require(imp.assets.first)
        #expect(asset.id != pip.id)
        #expect(asset.referencePhoto == photo)
        #expect(imp.images.contains(ref))
        #expect(imp.images.count == 2)   // the chosen image and the photo; the unchosen extra isn't

        let report = try await BookImporter.copyImages(imp.images, from: src.url, into: dst.store)
        #expect(report.copied == 2)
        #expect(exists(dst.store.imageURL(for: ref)))
    }

    @Test func importerWithoutAPhotoAddsNoExtraImage() async throws {
        var src = try DiskBook.make(title: "Src")
        let dst = try DiskBook.make(title: "Dst")
        defer { try? FileManager.default.removeItem(at: src.dir); try? FileManager.default.removeItem(at: dst.dir) }
        let pip = try await src.addAsset(name: "Pip", primaryBytes: "pip-front")
        let imp = try BookImporter.build(source: src.content, target: dst.content,
                                         selection: BookImportSelection(assets: [pip.id]))
        #expect(imp.assets.first?.referencePhoto == nil)
        #expect(imp.images.count == 1)
    }
}
