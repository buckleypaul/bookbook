import BBModel
import BBStore
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import BBUI

/// An asset's optional reference photo (PD §8.3): setting and removing it (undoable, no revision
/// bump), the three-way asset merge, and the Generate prompt and help text.
@MainActor
struct AssetReferencePhotoTests {
    struct Setup {
        var document: BookDocument
        var undo: UndoManager
        var url: URL
    }

    func makeDocument() throws -> Setup {
        let content = Fixtures.book(pages: 1)
        let url = FileManager.default.temporaryDirectory.appending(path: "RefPhoto-\(UUID().uuidString).bookbook")
        try BookStore.create(content, at: url)
        let document = BookDocument(content: content, store: BookStore(packageURL: url, debounce: .milliseconds(20)))
        let undo = UndoManager()
        undo.groupsByEvent = false
        document.undoManager = undo
        return Setup(document: document, undo: undo, url: url)
    }

    @discardableResult
    func grouped<T>(_ s: Setup, _ body: () throws -> T) rethrows -> T {
        s.undo.beginUndoGrouping()
        defer { s.undo.endUndoGrouping() }
        return try body()
    }

    func addPip(_ s: Setup) -> Asset {
        let pip = Asset.makeNew(type: .character, name: "Pip")
        #expect(grouped(s) { s.document.perform(.addAsset(pip)) })
        return s.document.content.assets[pip.id]!
    }

    /// A small JPEG built at runtime, written to a temp file.
    func writeJPEG(width: Int = 24, height: Int = 16) throws -> URL {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.9, green: 0.4, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        let url = FileManager.default.temporaryDirectory.appending(path: "photo-\(UUID().uuidString).jpg")
        try (data as Data).write(to: url)
        return url
    }

    /// Sets the photo inside one undo group (the await happens before `perform`, so the group
    /// is opened just around the call, as a single user action would be).
    func setPhoto(_ s: Setup, from file: URL, for id: AssetID, realPerson: Bool) async throws -> Bool {
        s.undo.beginUndoGrouping()
        defer { s.undo.endUndoGrouping() }
        return try await s.document.setAssetReferencePhoto(from: file, for: id, depictsRealPerson: realPerson)
    }

    // MARK: setAssetReferencePhoto

    @Test func setReferencePhoto_storesIt_leavesImageAndRevision_undoRedo() async throws {
        let s = try makeDocument()
        defer { try? FileManager.default.removeItem(at: s.url) }
        let pip = addPip(s)
        let version = Version(image: Fixtures.ref, pixelSize: PixelSize(width: 8, height: 8), source: .imported,
                              createdAt: Fixtures.date)
        s.document.performIrreversible { content in
            content.sessions[pip.sessionID]?.versions.append(version)
            content.assets[pip.id]?.chosen = version.id
            return DirtySet(sessions: [pip.sessionID], assets: [pip.id])
        }
        let before = try #require(s.document.content.assets[pip.id])
        let file = try writeJPEG()
        defer { try? FileManager.default.removeItem(at: file) }

        #expect(try await setPhoto(s, from: file, for: pip.id, realPerson: true))
        #expect(s.undo.undoActionName == "Set Reference Photo")
        let after = try #require(s.document.content.assets[pip.id])
        let photo = try #require(after.referencePhoto)
        #expect(photo.depictsRealPerson)
        #expect(photo.pixelSize == PixelSize(width: 24, height: 16))
        #expect(photo.image.contentType == "public.jpeg")
        #expect(FileManager.default.fileExists(atPath: s.document.store.imageURL(for: photo.image).path(percentEncoded: false)))
        #expect(after.chosen == before.chosen)
        #expect(after.revision == before.revision)
        #expect(after.revisionHighWater == before.revisionHighWater)
        #expect(after.name == before.name && after.description == before.description)

        s.undo.undo()
        #expect(s.document.content.assets[pip.id]?.referencePhoto == nil)
        #expect(s.document.content.assets[pip.id] == before)
        s.undo.redo()
        #expect(s.document.content.assets[pip.id]?.referencePhoto == photo)
        #expect(s.document.content.assets[pip.id]?.revision == before.revision)
    }

    @Test func setReferencePhoto_replacesAndAnswerIsKept_andFailures() async throws {
        let s = try makeDocument()
        defer { try? FileManager.default.removeItem(at: s.url) }
        let pip = addPip(s)
        let small = try writeJPEG(width: 10, height: 10)
        let wide = try writeJPEG(width: 30, height: 12)
        let notAnImage = FileManager.default.temporaryDirectory.appending(path: "nope-\(UUID().uuidString).jpg")
        try Data("not an image".utf8).write(to: notAnImage)
        defer { for url in [small, wide, notAnImage] { try? FileManager.default.removeItem(at: url) } }

        #expect(try await setPhoto(s, from: small, for: pip.id, realPerson: false))
        let first = try #require(s.document.content.assets[pip.id]?.referencePhoto)
        #expect(!first.depictsRealPerson)
        #expect(try await setPhoto(s, from: wide, for: pip.id, realPerson: true))
        let second = try #require(s.document.content.assets[pip.id]?.referencePhoto)
        #expect(second.depictsRealPerson && second.image != first.image)
        // The same file and answer again is no change (called outside a group: an empty group
        // would sit on top of the undo stack).
        #expect(try await s.document.setAssetReferencePhoto(from: wide, for: pip.id, depictsRealPerson: true) == false)
        #expect(s.undo.undoActionName == "Set Reference Photo")
        s.undo.undo()
        #expect(s.document.content.assets[pip.id]?.referencePhoto == first)

        await #expect(throws: ImageImportFailure.assetGone) {
            try await s.document.setAssetReferencePhoto(from: small, for: AssetID(), depictsRealPerson: false)
        }
        await #expect(throws: ImageImportFailure.notAnImage) {
            try await s.document.setAssetReferencePhoto(from: notAnImage, for: pip.id, depictsRealPerson: false)
        }
        await #expect(throws: ImageImportFailure.notAFileURL) {
            try await s.document.setAssetReferencePhoto(from: URL(string: "https://example.com/a.jpg")!, for: pip.id,
                                                        depictsRealPerson: false)
        }
        #expect(s.document.content.assets[pip.id]?.referencePhoto == first)
    }

    @Test func referencePhotoIsSaved() async throws {
        let s = try makeDocument()
        defer { try? FileManager.default.removeItem(at: s.url) }
        let pip = addPip(s)
        let file = try writeJPEG()
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(try await setPhoto(s, from: file, for: pip.id, realPerson: true))
        let photo = try #require(s.document.content.assets[pip.id]?.referencePhoto)
        await s.document.flush()
        let loaded = try await BookStore(packageURL: s.url).load()
        #expect(loaded.assets[pip.id]?.referencePhoto == photo)
    }

    // MARK: removeAssetReferencePhoto

    @Test func removeReferencePhoto_isUndoable_andFalseWithoutAPhoto() async throws {
        let s = try makeDocument()
        defer { try? FileManager.default.removeItem(at: s.url) }
        let pip = addPip(s)
        #expect(!s.document.removeAssetReferencePhoto(for: pip.id))
        #expect(!s.document.removeAssetReferencePhoto(for: AssetID()))

        let file = try writeJPEG()
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(try await setPhoto(s, from: file, for: pip.id, realPerson: false))
        let photo = try #require(s.document.content.assets[pip.id]?.referencePhoto)
        let revision = s.document.content.assets[pip.id]?.revision

        #expect(grouped(s) { s.document.removeAssetReferencePhoto(for: pip.id) })
        #expect(s.undo.undoActionName == "Remove Reference Photo")
        #expect(s.document.content.assets[pip.id]?.referencePhoto == nil)
        #expect(s.document.content.assets[pip.id]?.revision == revision)
        #expect(!s.document.removeAssetReferencePhoto(for: pip.id))

        s.undo.undo()
        #expect(s.document.content.assets[pip.id]?.referencePhoto == photo)
        s.undo.redo()
        #expect(s.document.content.assets[pip.id]?.referencePhoto == nil)
    }

    // MARK: mergeAsset

    @Test func undoRename_keepsAReferencePhotoSetSince() throws {
        let s = try makeDocument()
        defer { try? FileManager.default.removeItem(at: s.url) }
        var pip = addPip(s)
        pip.name = "Pippa"
        #expect(grouped(s) { s.document.perform(.updateAsset(pip, actionName: "Rename Asset")) })
        let photo = AssetReferencePhoto(image: Fixtures.ref, pixelSize: PixelSize(width: 8, height: 8),
                                        depictsRealPerson: true)
        s.document.performIrreversible { content in
            content.assets[pip.id]?.referencePhoto = photo
            return DirtySet(assets: [pip.id])
        }
        s.undo.undo()
        let after = try #require(s.document.content.assets[pip.id])
        #expect(after.name == "Pip")
        #expect(after.referencePhoto == photo)
        #expect(after.revision == 1)
    }

    @Test func undoReferencePhoto_keepsARenameMadeSince() async throws {
        let s = try makeDocument()
        defer { try? FileManager.default.removeItem(at: s.url) }
        let pip = addPip(s)
        let file = try writeJPEG()
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(try await setPhoto(s, from: file, for: pip.id, realPerson: false))
        s.document.performIrreversible { content in
            content.assets[pip.id]?.name = "Pippa"
            return DirtySet(assets: [pip.id])
        }
        s.undo.undo()
        let after = try #require(s.document.content.assets[pip.id])
        #expect(after.referencePhoto == nil)
        #expect(after.name == "Pippa")
    }

    @Test func mergeAsset_takesThePhotoOnlyWhenTheEditChangesIt() {
        let base = Asset.makeNew(type: .character, name: "Pip")
        let photo = AssetReferencePhoto(image: Fixtures.ref, depictsRealPerson: false)
        var withPhoto = base
        withPhoto.referencePhoto = photo

        // The edit sets the photo.
        let set = BookDocument.mergeAsset(current: base, from: base, to: withPhoto)
        #expect(set.referencePhoto == photo)
        #expect(set.revision == base.revision)

        // An unrelated edit (rename) leaves a live photo alone.
        var renamed = base
        renamed.name = "Pippa"
        let merged = BookDocument.mergeAsset(current: withPhoto, from: base, to: renamed)
        #expect(merged.referencePhoto == photo)
        #expect(merged.name == "Pippa")
        #expect(merged.revision == base.revision)
    }

    // MARK: Generate prompt and help

    @Test func promptFallsBackToThePhotoOnlyWhenTheDescriptionIsEmpty() {
        #expect(AssetGeneration.prompt(from: "  a red fox \n", name: "Pip", hasReferencePhoto: true) == "a red fox")
        #expect(AssetGeneration.prompt(from: "a red fox", name: "Pip", hasReferencePhoto: false) == "a red fox")
        #expect(AssetGeneration.prompt(from: " \n ", name: "Pip", hasReferencePhoto: true)
            == "Draw Pip from the reference photo.")
        #expect(AssetGeneration.prompt(from: " \n ", name: "Pip", hasReferencePhoto: false).isEmpty)
    }

    @Test func generateAndPhotoHelp() {
        #expect(AssetGeneration.generateHelp(prompt: "", hasReferencePhoto: false)
            == "Write a description or add a reference photo first")
        #expect(AssetGeneration.generateHelp(prompt: "a fox", hasReferencePhoto: false)
            == "Make a new picture from the description")
        #expect(AssetGeneration.generateHelp(prompt: "a fox", hasReferencePhoto: true)
            == "Make a new picture from the description and the reference photo")
        #expect(AssetGeneration.referencePhotoHelp(name: "Pip", hasPhoto: false).hasPrefix("Optional:"))
        #expect(AssetGeneration.referencePhotoHelp(name: "Pip", hasPhoto: false).contains("Pip"))
        #expect(AssetGeneration.referencePhotoHelp(name: "Pip", hasPhoto: true).contains("Pip"))
        #expect(AssetGeneration.referencePhotoHelp(name: "Pip", hasPhoto: true).contains("only when you press"))
    }
}
