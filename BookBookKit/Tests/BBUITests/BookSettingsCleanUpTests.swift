import BBModel
import BBStore
import Foundation
import Testing
@testable import BBUI

/// Phase 16 Clean up from Book Settings: plan, irreversible apply, file deletion, size.
@MainActor
struct BookSettingsCleanUpTests {
    @Test func cleanUpRemovesPlannedVersionsAndFilesButKeepsPlacedAndStarred() async throws {
        var content = Fixtures.book()
        let url = FileManager.default.temporaryDirectory.appending(path: "Clean-\(UUID().uuidString).bookbook", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: url) }
        try BookStore.create(content, at: url)
        let store = BookStore(packageURL: url, debounce: .milliseconds(20))
        let pageID = Fixtures.firstPage(content)
        let (boxID, slot) = try #require(content.pages[pageID]?.images.first)

        func add(_ bytes: String, starred: Bool = false) async throws -> Version {
            let ref = try await store.storeImage(Data((bytes + String(repeating: "x", count: 5000)).utf8), contentType: "public.png")
            let v = Version(image: ref, pixelSize: PixelSize(width: 8, height: 8), source: .generated,
                            createdAt: Fixtures.date, starred: starred)
            content.sessions[slot.sessionID]?.versions.append(v)
            return v
        }
        let placed = try await add("placed")
        let starred = try await add("starred", starred: true)
        let loose1 = try await add("loose1")
        let loose2 = try await add("loose2")
        content.pages[pageID]?.images[boxID]?.placement = ImagePlacement(versionID: placed.id, boxAspectWhenPlaced: 1)
        try await store.save(content, dirty: .all(content))

        let document = BookDocument(content: content, store: store)
        let undo = UndoManager()
        document.undoManager = undo
        undo.registerUndo(withTarget: document) { _ in }
        #expect(undo.canUndo)
        let model = StorageModel()
        await model.refresh(document)
        #expect(model.plan.versionIDs == [loose1.id, loose2.id])
        #expect(model.plan.bytesFreed > 0)
        let before = model.size
        let planned = model.plan.bytesFreed

        let message = await model.cleanUp(document)
        #expect(message == nil)
        // Clean up keeps the undo history (replay skips the removed versions).
        #expect(undo.canUndo)
        let versions = document.content.sessions[slot.sessionID]?.versions.map(\.id) ?? []
        #expect(Set(versions) == [placed.id, starred.id])
        #expect(!FileManager.default.fileExists(atPath: store.imageURL(for: loose1.image).path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: store.imageURL(for: loose2.image).path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: store.imageURL(for: placed.image).path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: store.imageURL(for: starred.image).path(percentEncoded: false)))
        #expect(model.plan.isEmpty)
        #expect(model.size < before)
        #expect(before - model.size >= planned / 2)

        let reloaded = try await BookStore(packageURL: url).load()
        #expect(Set(reloaded.sessions[slot.sessionID]?.versions.map(\.id) ?? []) == [placed.id, starred.id])
    }

    @Test func refreshAfterCleanUpKeepsProtectedVersions() async throws {
        var content = Fixtures.book()
        let url = FileManager.default.temporaryDirectory.appending(path: "Clean-\(UUID().uuidString).bookbook", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: url) }
        try BookStore.create(content, at: url)
        let store = BookStore(packageURL: url, debounce: .milliseconds(20))
        let pageID = Fixtures.firstPage(content)
        let slot = try #require(content.pages[pageID]?.images.first?.value)
        var versions: [Version] = []
        for name in ["queued", "loose"] {
            let ref = try await store.storeImage(Data((name + String(repeating: "x", count: 5000)).utf8), contentType: "public.png")
            let v = Version(image: ref, pixelSize: PixelSize(width: 8, height: 8), source: .generated, createdAt: Fixtures.date)
            content.sessions[slot.sessionID]?.versions.append(v)
            versions.append(v)
        }
        try await store.save(content, dirty: .all(content))
        let document = BookDocument(content: content, store: store)
        let model = StorageModel()
        let protecting: Set<VersionID> = [versions[0].id]
        await model.refresh(document, protecting: protecting)
        #expect(model.plan.versionIDs == [versions[1].id])
        #expect(await model.cleanUp(document, protecting: protecting) == nil)
        // The queued request's version is still not offered for deletion.
        #expect(model.plan.isEmpty)
        #expect(document.content.sessions[slot.sessionID]?.version(versions[0].id) != nil)
    }

    @Test func readOnlyBookDoesNothing() async throws {
        let content = Fixtures.book()
        let url = FileManager.default.temporaryDirectory.appending(path: "Clean-\(UUID().uuidString).bookbook", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: url) }
        try BookStore.create(content, at: url)
        let document = try await BookDocument.open(at: url, readOnly: true)
        let model = StorageModel()
        await model.refresh(document)
        #expect(await model.cleanUp(document) == nil)
    }

    @Test func costLabelsFollowPD() {
        #expect(BookSettingsSheet.costLabel(.image) == "Images")
        #expect(BookSettingsSheet.costLabel(.consistency) == "Consistency checks")
        #expect(BookSettingsSheet.costLabel(.template) == "Templates")
    }
}
