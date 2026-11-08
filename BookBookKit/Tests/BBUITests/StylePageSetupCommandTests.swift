import BBAI
import BBAICore
import BBModel
import BBStore
import Foundation
import Testing
@testable import BBUI

/// `.setStyleVisual`, `.setPageSetup`, `.markFlagsOK` and baseline clearing on placement (Phase 7).
@MainActor
struct StylePageSetupCommandTests {
    func makeDocument() throws -> (BookDocument, UndoManager) {
        let content = Fixtures.book()
        let url = FileManager.default.temporaryDirectory.appending(path: "StyleSetup-\(UUID().uuidString).bookbook")
        try BookStore.create(content, at: url)
        let document = BookDocument(content: content, store: BookStore(packageURL: url))
        let undo = UndoManager()
        undo.groupsByEvent = false
        document.undoManager = undo
        return (document, undo)
    }

    func group(_ undo: UndoManager, _ body: () -> Void) {
        undo.beginUndoGrouping()
        body()
        undo.endUndoGrouping()
    }

    /// Adds a generated version (provenance style revision `styleRevision`) and places it.
    func place(_ doc: BookDocument, _ undo: UndoManager, styleRevision: Int = 0) -> (PageID, VersionID) {
        let page = Fixtures.firstPage(doc.content)
        var provenance = Fixtures.provenance()
        provenance.styleRevision = styleRevision
        let version = Version(image: Fixtures.ref, pixelSize: PixelSize(width: 1024, height: 1024), source: .generated,
                              createdAt: Fixtures.date, provenance: provenance)
        let sessionID = doc.content.pages[page]!.images[Fixtures.imageBox.id]!.sessionID
        doc.performIrreversible { content in
            content.sessions[sessionID]?.versions.append(version)
            return DirtySet(sessions: [sessionID])
        }
        group(undo) { #expect(doc.perform(.chooseVersion(page: page, box: Fixtures.imageBox.id, version: version.id))) }
        return (page, version.id)
    }

    @Test func setStyleVisual_bumpsRevisionAndUndoes() throws {
        let (doc, undo) = try makeDocument()
        let original = doc.content.style
        var visual = original.visual
        visual.visualDescription = "Soft watercolour"
        group(undo) { #expect(doc.perform(.setStyleVisual(visual))) }
        #expect(doc.content.style.visualDescription == "Soft watercolour")
        #expect(doc.content.style.visualRevision == original.visualRevision + 1)
        #expect(undo.undoActionName == "Change Style")

        undo.undo()
        #expect(doc.content.style == original)
        undo.redo()
        #expect(doc.content.style.visualRevision == original.visualRevision + 1)
    }

    @Test func setStyleVisual_presetAloneDoesNotBump() throws {
        let (doc, undo) = try makeDocument()
        var visual = doc.content.style.visual
        visual.presetID = "crayon"
        group(undo) { #expect(doc.perform(.setStyleVisual(visual))) }
        #expect(doc.content.style.presetID == "crayon")
        #expect(doc.content.style.visualRevision == 0)
        undo.undo()
        #expect(doc.content.style.presetID == nil)
    }

    @Test func setStyleVisual_noOp() throws {
        let (doc, undo) = try makeDocument()
        #expect(!doc.perform(.setStyleVisual(doc.content.style.visual)))
        #expect(!undo.canUndo)
    }

    @Test func setPageSetup_undoRedo_andNoOp() throws {
        let (doc, undo) = try makeDocument()
        let original = doc.content.style.pageSetup
        #expect(!doc.perform(.setPageSetup(original)))
        #expect(!undo.canUndo)

        let square = original.applying(preset: .square8, orientation: .square)
        group(undo) { #expect(doc.perform(.setPageSetup(square))) }
        #expect(doc.content.style.pageSetup == square)
        #expect(undo.undoActionName == "Change Page Setup")
        undo.undo()
        #expect(doc.content.style.pageSetup == original)
        undo.redo()
        #expect(doc.content.style.pageSetup == square)
    }

    @Test func setPageSetup_flagsLayoutChanged_andMarkOKClearsIt() throws {
        let (doc, undo) = try makeDocument()
        let (page, _) = place(doc, undo)
        let box = Fixtures.imageBox.id
        #expect(doc.content.imageFlags(page: page, box: box).isEmpty)

        group(undo) { doc.perform(.setPageSetup(doc.content.style.pageSetup.applying(preset: .square8, orientation: .square))) }
        #expect(doc.content.imageFlags(page: page, box: box) == .layoutChanged)

        group(undo) { #expect(doc.perform(.markFlagsOK(page: page, box: box))) }
        #expect(doc.content.imageFlags(page: page, box: box).isEmpty)
        #expect(undo.undoActionName == "Mark as OK")
        undo.undo()
        #expect(doc.content.imageFlags(page: page, box: box) == .layoutChanged)
        undo.redo()
        #expect(doc.content.imageFlags(page: page, box: box).isEmpty)
    }

    @Test func markFlagsOK_clearsStyleChanged_keepsAssetRevisions() throws {
        let (doc, undo) = try makeDocument()
        let (page, _) = place(doc, undo)
        let box = Fixtures.imageBox.id
        let asset = AssetID()
        doc.performIrreversible { content in
            content.pages[page]?.images[box]?.acknowledged.assetRevisions[asset] = 3
            return DirtySet(pages: [page])
        }
        var visual = doc.content.style.visual
        visual.visualDescription = "Crayon"
        group(undo) { doc.perform(.setStyleVisual(visual)) }
        #expect(doc.content.imageFlags(page: page, box: box) == .styleChanged)

        // box: nil marks every image box on the page.
        group(undo) { #expect(doc.perform(.markFlagsOK(page: page, box: nil))) }
        let ack = try #require(doc.content.pages[page]?.images[box]?.acknowledged)
        #expect(ack.styleRevision == 1)
        #expect(ack.assetRevisions == [asset: 3])
        #expect(doc.content.imageFlags(page: page, box: box).isEmpty)

        // Nothing left to acknowledge.
        #expect(!doc.perform(.markFlagsOK(page: page, box: box)))
    }

    @Test func markFlagsOK_noPlacementOrMissingTarget_returnsNothing() throws {
        let (doc, undo) = try makeDocument()
        let page = Fixtures.firstPage(doc.content)
        #expect(!doc.perform(.markFlagsOK(page: page, box: Fixtures.imageBox.id)))
        #expect(!doc.perform(.markFlagsOK(page: PageID(), box: nil)))
        #expect(!undo.canUndo)
    }

    @Test func placingANewVersionClearsAcknowledgedAspect_andUndoRestoresIt() throws {
        let (doc, undo) = try makeDocument()
        let (page, _) = place(doc, undo)
        let box = Fixtures.imageBox.id
        group(undo) { doc.perform(.markFlagsOK(page: page, box: box)) }
        let acknowledged = try #require(doc.content.pages[page]?.images[box]?.acknowledged)
        #expect(acknowledged.boxAspect != nil)

        let (_, second) = place(doc, undo)
        #expect(doc.content.pages[page]?.images[box]?.acknowledged.boxAspect == nil)
        #expect(doc.content.pages[page]?.images[box]?.placement?.versionID == second)
        undo.undo()
        #expect(doc.content.pages[page]?.images[box]?.acknowledged == acknowledged)
    }

    @Test func deliveryAutoPlacementClearsAcknowledgedAspect() throws {
        var content = Fixtures.book()
        let page = Fixtures.firstPage(content)
        let box = Fixtures.imageBox.id
        content.pages[page]?.images[box]?.acknowledged.boxAspect = 2
        let (message, item) = BookMutations.makeGeneration(
            prompt: "a fox", refines: nil, defaults: GenerationDefaults(), bookID: content.book.id,
            page: page, box: box, now: Fixtures.date)
        _ = BookMutations.appendPendingMessage(message, page: page, box: box, to: &content)
        let delivery = GenerationDelivery(item: item, outcome: .success(result: Fixtures.result(),
                                                                         provenance: Fixtures.provenance()))
        _ = BookMutations.applyDelivery(delivery, storedImage: Fixtures.ref, to: &content, now: Fixtures.date)
        #expect(content.pages[page]?.images[box]?.placement != nil)
        #expect(content.pages[page]?.images[box]?.acknowledged.boxAspect == nil)
    }
}
