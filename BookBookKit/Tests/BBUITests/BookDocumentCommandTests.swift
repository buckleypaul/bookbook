import BBModel
import BBStore
import Foundation
import Testing
@testable import BBUI

/// The command and undo layer (A §6.3, plan P-3). Owned by the main thread with BookDocument.
@MainActor
struct BookDocumentCommandTests {
    let story = Template(
        name: "Image above text", kind: .single,
        boxes: [
            Box(frame: NormalizedRect(x: 0.1, y: 0.1, width: 0.8, height: 0.5), content: .image),
            Box(frame: NormalizedRect(x: 0.1, y: 0.65, width: 0.8, height: 0.25), content: .text(TextBoxStyle())),
        ])
    let cover = Template(
        name: "Cover", kind: .cover,
        boxes: [Box(frame: NormalizedRect(x: 0, y: 0, width: 1, height: 1), content: .image)])

    var imageBox: Box { story.imageBoxes[0] }
    var textBox: Box { story.textBoxes[0] }

    func makeDocument() throws -> (BookDocument, UndoManager) {
        let content = BookContent.makeNew(title: "Test", storyTemplate: story, coverTemplate: cover,
                                          now: Date(timeIntervalSince1970: 0))
        let url = FileManager.default.temporaryDirectory
            .appending(path: "BookDocumentTests-\(UUID().uuidString).bookbook")
        try BookStore.create(content, at: url)
        let document = BookDocument(content: content, store: BookStore(packageURL: url))
        let undo = UndoManager()
        undo.groupsByEvent = false
        document.undoManager = undo
        return (document, undo)
    }

    /// Runs `body` in its own undo group (the run loop isn't grouping for us).
    func group(_ undo: UndoManager, _ body: () -> Void) {
        undo.beginUndoGrouping()
        body()
        undo.endUndoGrouping()
    }

    var firstPage: (BookDocument) -> PageID = { $0.content.book.pageOrder[0] }

    @Test func setRichText_undoRedo() throws {
        let (doc, undo) = try makeDocument()
        let page = firstPage(doc)
        group(undo) { #expect(doc.perform(.setRichText(page: page, box: textBox.id, text: RichText(plain: "Once")))) }
        group(undo) { doc.perform(.setRichText(page: page, box: textBox.id, text: RichText(plain: "Once upon"))) }
        #expect(doc.content.pages[page]?.text[textBox.id]?.plainText == "Once upon")
        #expect(undo.undoActionName == "Typing")

        undo.undo()
        #expect(doc.content.pages[page]?.text[textBox.id]?.plainText == "Once")
        undo.undo()
        #expect(doc.content.pages[page]?.text[textBox.id] == nil)
        undo.redo()
        undo.redo()
        #expect(doc.content.pages[page]?.text[textBox.id]?.plainText == "Once upon")
    }

    @Test func setRichText_onImageBoxIsRejected() throws {
        let (doc, undo) = try makeDocument()
        #expect(!doc.perform(.setRichText(page: firstPage(doc), box: imageBox.id, text: RichText(plain: "x"))))
        #expect(!undo.canUndo)
    }

    @Test func chooseVersion_needsAnExistingVersion_andUndoes() throws {
        let (doc, undo) = try makeDocument()
        let page = firstPage(doc)
        let missing = VersionID()
        #expect(!doc.perform(.chooseVersion(page: page, box: imageBox.id, version: missing)))

        let version = addVersion(to: doc, page: page)
        #expect(!undo.canUndo, "AI results are not undoable")
        group(undo) { #expect(doc.perform(.chooseVersion(page: page, box: imageBox.id, version: version))) }
        let placement = try #require(doc.content.pages[page]?.images[imageBox.id]?.placement)
        #expect(placement.versionID == version)
        #expect(placement.zoom == 1)
        #expect(abs(placement.boxAspectWhenPlaced - (0.8 * 612) / (0.5 * 792)) < 1e-9)

        undo.undo()
        #expect(doc.content.pages[page]?.images[imageBox.id]?.placement == nil)
        undo.redo()
        #expect(doc.content.pages[page]?.images[imageBox.id]?.placement?.versionID == version)
    }

    @Test func undo_doesNothingWhenTheVersionWasDeleted() throws {
        let (doc, undo) = try makeDocument()
        let page = firstPage(doc)
        let first = addVersion(to: doc, page: page)
        let second = addVersion(to: doc, page: page)
        group(undo) { doc.perform(.chooseVersion(page: page, box: imageBox.id, version: first)) }
        group(undo) { doc.perform(.chooseVersion(page: page, box: imageBox.id, version: second)) }
        // Delete the first version (non-undoable), then undo back towards it.
        let sessionID = try #require(doc.content.pages[page]?.images[imageBox.id]?.sessionID)
        doc.performIrreversible { content in
            content.sessions[sessionID]?.versions.removeAll { $0.id == first }
            return DirtySet(sessions: [sessionID])
        }
        undo.undo()
        #expect(doc.content.pages[page]?.images[imageBox.id]?.placement?.versionID == second,
                "undo must not resurrect a deleted version")
    }

    @Test func addAndDeletePage_undoRedo() throws {
        let (doc, undo) = try makeDocument()
        let original = firstPage(doc)
        group(undo) { #expect(doc.perform(.addPage(index: 1, templateID: story.id))) }
        #expect(doc.content.book.pageOrder.count == 2)
        let added = doc.content.book.pageOrder[1]
        let addedPage = try #require(doc.content.pages[added])
        #expect(addedPage.images[imageBox.id].map { doc.content.sessions[$0.sessionID] != nil } == true)

        group(undo) { #expect(doc.perform(.deletePage(original))) }
        #expect(doc.content.book.pageOrder == [added])
        #expect(doc.content.pages[original] == nil)

        undo.undo()
        #expect(doc.content.book.pageOrder == [original, added])
        undo.undo()
        #expect(doc.content.book.pageOrder == [original])
        undo.redo()
        #expect(doc.content.book.pageOrder == [original, added], "redo restores the same page ID")
        #expect(doc.content.pages[added] == addedPage)
    }

    @Test func addPage_rejectsCoverTemplate() throws {
        let (doc, _) = try makeDocument()
        #expect(!doc.perform(.addPage(index: 0, templateID: cover.id)))
    }

    @Test func performIrreversible_registersNoUndo_andFlushSaves() async throws {
        let (doc, undo) = try makeDocument()
        let page = firstPage(doc)
        _ = addVersion(to: doc, page: page)
        #expect(!undo.canUndo)
        await doc.flush()
        #expect(doc.lastSaveError == nil)
        let reloaded = try await BookStore(packageURL: doc.store.packageURL).load()
        #expect(reloaded == doc.content)
    }

    /// Adds a generated version to the page's image-box session, as a delivery would.
    @discardableResult
    func addVersion(to doc: BookDocument, page: PageID) -> VersionID {
        let version = Version(image: ImageRef(sha256: UUID().uuidString, contentType: "public.png"),
                              pixelSize: PixelSize(width: 1024, height: 1024), source: .generated,
                              createdAt: Date(timeIntervalSince1970: 1))
        let sessionID = doc.content.pages[page]!.images[imageBox.id]!.sessionID
        doc.performIrreversible { content in
            content.sessions[sessionID]?.versions.append(version)
            return DirtySet(sessions: [sessionID])
        }
        return version.id
    }
}
