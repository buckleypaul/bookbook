import BBModel
import BBStore
import Foundation
import Testing
@testable import BBUI

/// Undo and redo after versions were removed outside the undo stack (Delete Version, Clean up):
/// replay never points a placement or an asset's choice at a version that is gone, and Clean up
/// keeps the undo history and the files that history could bring back.
@MainActor
struct UndoAfterVersionRemovalTests {
    struct Setup {
        var document: BookDocument
        var store: BookStore
        var undo: UndoManager
        var url: URL
    }

    func makeDocument(_ content: BookContent = Fixtures.book(pages: 2)) throws -> Setup {
        let url = FileManager.default.temporaryDirectory.appending(path: "UndoGone-\(UUID().uuidString).bookbook",
                                                                   directoryHint: .isDirectory)
        try BookStore.create(content, at: url)
        let store = BookStore(packageURL: url, debounce: .milliseconds(20))
        let document = BookDocument(content: content, store: store)
        let undo = UndoManager()
        undo.groupsByEvent = false
        document.undoManager = undo
        return Setup(document: document, store: store, undo: undo, url: url)
    }

    @discardableResult
    func grouped(_ s: Setup, _ body: () -> Bool) -> Bool {
        s.undo.beginUndoGrouping()
        defer { s.undo.endUndoGrouping() }
        return body()
    }

    func version(_ image: ImageRef = Fixtures.ref) -> Version {
        Version(image: image, pixelSize: PixelSize(width: 8, height: 8), source: .imported, createdAt: Fixtures.date)
    }

    func append(_ version: Version, to session: SessionID, in doc: BookDocument) {
        doc.performIrreversible { content in
            content.sessions[session]?.versions.append(version)
            return DirtySet(sessions: [session])
        }
    }

    func cleanUp(_ s: Setup) async {
        let model = StorageModel()
        await model.refresh(s.document)
        #expect(await model.cleanUp(s.document) == nil)
    }

    // MARK: Asset choice (A)

    @Test func undoChoose_afterTheEarlierChoiceWasDeleted_keepsTheLiveChoice() throws {
        let s = try makeDocument()
        defer { try? FileManager.default.removeItem(at: s.url) }
        let pip = Asset.makeNew(type: .character, name: "Pip")
        #expect(grouped(s) { s.document.perform(.addAsset(pip)) })
        let v1 = version(), v2 = version()
        append(v1, to: pip.sessionID, in: s.document)
        append(v2, to: pip.sessionID, in: s.document)
        #expect(grouped(s) { s.document.chooseAssetImage(v1.id, for: pip.id) })
        #expect(grouped(s) { s.document.chooseAssetImage(v2.id, for: pip.id) })
        #expect(s.document.deleteVersion(v1.id, owner: pip.owner))

        s.undo.undo()
        let chosen = s.document.content.assets[pip.id]?.chosen
        #expect(chosen == v2.id)
        if let chosen { #expect(s.document.content.sessions[pip.sessionID]?.version(chosen) != nil) }
        // Undoing further (back to nothing chosen) and redoing still never lands on v1.
        s.undo.undo()
        #expect(s.document.content.assets[pip.id]?.chosen == nil)
        s.undo.redo()
        #expect(s.document.content.assets[pip.id]?.chosen != v1.id)
    }

    @Test func mergeAsset_neverTakesAGoneChoice() {
        var from = Asset.makeNew(type: .character, name: "Pip")
        let gone = VersionID(), live = VersionID()
        from.chosen = live
        var to = from
        to.chosen = gone
        let merged = BookDocument.mergeAsset(current: from, from: from, to: to) { $0 != gone }
        #expect(merged.chosen == live)
        // A live choice that has gone is cleared.
        let cleared = BookDocument.mergeAsset(current: to, from: to, to: to) { $0 != gone }
        #expect(cleared.chosen == nil)
    }

    @Test func redoAddAsset_afterCleanUpRemovedItsChoice_choosesNothing() async throws {
        let s = try makeDocument()
        defer { try? FileManager.default.removeItem(at: s.url) }
        let pip = Asset.makeNew(type: .character, name: "Pip")
        #expect(grouped(s) { s.document.perform(.addAsset(pip)) })
        let v1 = version()
        append(v1, to: pip.sessionID, in: s.document)
        // A delivery chooses it (not undoable).
        s.document.performIrreversible { content in
            content.assets[pip.id]?.chosen = v1.id
            return DirtySet(assets: [pip.id])
        }
        s.undo.undo()
        #expect(s.document.content.assets[pip.id] == nil)
        await cleanUp(s)
        #expect(s.document.content.sessions[pip.sessionID]?.version(v1.id) == nil)

        s.undo.redo()
        let restored = try #require(s.document.content.assets[pip.id])
        #expect(restored.chosen == nil)
        #expect(restored.revision > 1)
    }

    // MARK: Placements on restored pages (B)

    @Test func undoDeletePage_afterCleanUp_restoresThePageWithoutTheGonePlacement() async throws {
        let s = try makeDocument()
        defer { try? FileManager.default.removeItem(at: s.url) }
        let pageID = Fixtures.firstPage(s.document.content)
        let (boxID, slot) = try #require(s.document.content.pages[pageID]?.images.first)
        let v1 = version()
        append(v1, to: slot.sessionID, in: s.document)
        #expect(grouped(s) { s.document.perform(.chooseVersion(page: pageID, box: boxID, version: v1.id)) })
        #expect(grouped(s) { s.document.perform(.deletePage(pageID)) })
        await cleanUp(s)
        #expect(s.document.content.sessions[slot.sessionID]?.version(v1.id) == nil)

        #expect(s.undo.canUndo)
        s.undo.undo()
        let page = try #require(s.document.content.pages[pageID])
        #expect(page.images[boxID]?.placement == nil)
        #expect(s.document.content.book.pageOrder.contains(pageID))
    }

    @Test func undoStillWorksAfterCleanUp() async throws {
        let s = try makeDocument()
        defer { try? FileManager.default.removeItem(at: s.url) }
        let pageID = Fixtures.firstPage(s.document.content)
        let (_, slot) = try #require(s.document.content.pages[pageID]?.images.first)
        append(version(), to: slot.sessionID, in: s.document)
        #expect(grouped(s) { s.document.perform(.setPageDone(pageID, true)) })
        await cleanUp(s)
        #expect(s.document.content.sessions[slot.sessionID]?.versions.isEmpty == true)
        #expect(s.undo.canUndo)
        s.undo.undo()
        #expect(s.document.content.pages[pageID]?.isDone == false)
    }

    // MARK: Files the undo history can bring back

    @Test func cleanUpKeepsAStyleReferenceFileThatUndoCanRestore() async throws {
        let s = try makeDocument()
        defer { try? FileManager.default.removeItem(at: s.url) }
        let ref = try await s.store.storeImage(Data(("style" + String(repeating: "x", count: 4000)).utf8),
                                               contentType: "public.png")
        let pageID = Fixtures.firstPage(s.document.content)
        let (_, slot) = try #require(s.document.content.pages[pageID]?.images.first)
        // A loose version made from the same bytes, and the style guide using it.
        append(version(ref), to: slot.sessionID, in: s.document)
        var visual = s.document.content.style.visual
        visual.styleReferences = [ref]
        #expect(grouped(s) { s.document.perform(.setStyleVisual(visual)) })
        visual.styleReferences = []
        #expect(grouped(s) { s.document.perform(.setStyleVisual(visual)) })

        let model = StorageModel()
        await model.refresh(s.document)
        // The loose version goes, but its file stays for undo, so the sheet doesn't count it.
        #expect(model.plan.versionIDs.count == 1)
        #expect(!model.plan.fileNames.contains(ref.fileName))
        #expect(model.plan.bytesFreed == 0)
        #expect(await model.cleanUp(s.document) == nil)
        let path = s.store.imageURL(for: ref).path(percentEncoded: false)
        #expect(FileManager.default.fileExists(atPath: path))

        s.undo.undo()
        #expect(s.document.content.style.styleReferences == [ref])
        #expect(FileManager.default.fileExists(atPath: path))
    }
}
