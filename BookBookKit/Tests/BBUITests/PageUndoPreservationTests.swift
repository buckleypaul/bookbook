import BBLayout
import BBModel
import BBStore
import CryptoKit
import Foundation
import Testing
@testable import BBUI

/// Phase 8 follow-ups in the page commands: moved slots re-own their sessions, a page restored
/// by undoing its deletion gets slots for image boxes its template gained, and undoing
/// `setPageDone` / `setPageTemplate` keeps a version an AI delivery placed in the meantime.
@MainActor
struct PageUndoPreservationTests {
    let story = try! Presets.storyTemplate()                        // image (top), text
    let cover = try! Presets.coverTemplate()
    let textLeftID = Presets.textLeftImageRightTemplateID
    let textOnlyID = Presets.textOnlyTemplateID

    var storyImage: BoxID { story.imageBoxes[0].id }

    func makeDocument(pages: Int = 1) throws -> (BookDocument, UndoManager) {
        let content = BookContent.makeNew(title: "Test", storyTemplate: story, coverTemplate: cover,
                                          storyPageCount: pages, now: Date(timeIntervalSince1970: 0))
        let url = FileManager.default.temporaryDirectory
            .appending(path: "PageUndoPreservationTests-\(UUID().uuidString).bookbook")
        try BookStore.create(content, at: url)
        let document = BookDocument(content: content, store: BookStore(packageURL: url))
        let undo = UndoManager()
        undo.groupsByEvent = false
        document.undoManager = undo
        return (document, undo)
    }

    @discardableResult
    func perform(_ doc: BookDocument, _ undo: UndoManager, _ command: BookCommand) -> Bool {
        undo.beginUndoGrouping()
        defer { undo.endUndoGrouping() }
        return doc.perform(command)
    }

    /// An AI delivery: adds a version to the slot's session and places it, irreversibly
    /// (as `BookMutations` auto-places into an empty box).
    @discardableResult
    func deliver(_ doc: BookDocument, page: PageID, box: BoxID) throws -> ImagePlacement {
        let sessionID = try #require(doc.content.pages[page]?.images[box]?.sessionID)
        let sha = SHA256.hash(data: Data(UUID().uuidString.utf8)).map { String(format: "%02x", $0) }.joined()
        let version = Version(image: ImageRef(sha256: sha, contentType: "public.png"),
                              pixelSize: PixelSize(width: 1024, height: 1024), source: .generated,
                              createdAt: Date(timeIntervalSince1970: 1))
        let placement = ImagePlacement(versionID: version.id, boxAspectWhenPlaced: 1.5)
        doc.performIrreversible { content in
            content.sessions[sessionID]?.versions.append(version)
            content.pages[page]?.images[box]?.placement = placement
            return DirtySet(pages: [page], sessions: [sessionID])
        }
        return placement
    }

    func owner(_ doc: BookDocument, page: PageID, box: BoxID) -> SessionOwner? {
        doc.content.pages[page]?.images[box].flatMap { doc.content.sessions[$0.sessionID]?.owner }
    }

    // MARK: Owners follow moved slots

    @Test func setPageTemplate_reownsMovedSessions_andUndoRestores() throws {
        let (doc, undo) = try makeDocument()
        let page = doc.content.book.pageOrder[0]
        let sessionID = try #require(doc.content.pages[page]?.images[storyImage]?.sessionID)
        #expect(doc.content.sessions[sessionID]?.owner == .pageBox(page, storyImage))

        #expect(perform(doc, undo, .setPageTemplate(page: page, templateID: textLeftID)))
        let newBox = try #require(doc.content.templates[textLeftID]?.imageBoxes.first?.id)
        #expect(newBox != storyImage)
        #expect(doc.content.pages[page]?.images[newBox]?.sessionID == sessionID, "the slot moved")
        #expect(doc.content.sessions[sessionID]?.owner == .pageBox(page, newBox))

        undo.undo()
        #expect(doc.content.sessions[sessionID]?.owner == .pageBox(page, storyImage))
        undo.redo()
        #expect(doc.content.sessions[sessionID]?.owner == .pageBox(page, newBox))
    }

    @Test func setPageTemplate_droppedSlotKeepsItsOwner_andUndoBringsItBack() throws {
        let (doc, undo) = try makeDocument()
        let page = doc.content.book.pageOrder[0]
        let slot = try #require(doc.content.pages[page]?.images[storyImage])
        #expect(perform(doc, undo, .setPageTemplate(page: page, templateID: textOnlyID)))
        #expect(doc.content.pages[page]?.images.isEmpty == true)
        #expect(doc.content.sessions[slot.sessionID]?.owner == .pageBox(page, storyImage))
        undo.undo()
        #expect(doc.content.pages[page]?.images[storyImage] == slot)
    }

    // MARK: Lazy slots on undoing a deletion

    @Test func undoDelete_addsSlotsForImageBoxesTheTemplateGainedSince() throws {
        let (doc, undo) = try makeDocument(pages: 2)
        let deleted = doc.content.book.pageOrder[1]
        #expect(perform(doc, undo, .deletePage(deleted)))

        // The template gains an image box while the page is gone (here outside the undo stack,
        // as from another undo history).
        var grown = try #require(doc.content.templates[story.id])
        let added = Box(frame: NormalizedRect(x: 0.6, y: 0.7, width: 0.3, height: 0.2), content: .image)
        grown.boxes.append(added)
        doc.performIrreversible { content in
            content.templates[grown.id] = grown
            return DirtySet(templates: [grown.id])
        }
        let sessionsBefore = Set(doc.content.sessions.keys)

        undo.undo()
        let restored = try #require(doc.content.pages[deleted])
        let slot = try #require(restored.images[added.id])
        #expect(!sessionsBefore.contains(slot.sessionID), "a new empty session")
        #expect(doc.content.sessions[slot.sessionID]?.owner == .pageBox(deleted, added.id))
        #expect(doc.content.sessions[slot.sessionID]?.versions.isEmpty == true)
        #expect(restored.images[storyImage] != nil, "existing slots are kept")

        // Redo deletes it again; a second undo brings back the same slot (no new session).
        undo.redo()
        #expect(doc.content.pages[deleted] == nil)
        undo.undo()
        #expect(doc.content.pages[deleted]?.images[added.id] == slot)
    }

    // MARK: Targeted inverses keep later deliveries

    @Test func setPageDone_undoKeepsALaterDeliveredPlacement() throws {
        let (doc, undo) = try makeDocument()
        let page = doc.content.book.pageOrder[0]
        #expect(perform(doc, undo, .setPageDone(page, true)))
        let placement = try deliver(doc, page: page, box: storyImage)

        undo.undo()
        #expect(doc.content.pages[page]?.isDone == false)
        #expect(doc.content.pages[page]?.images[storyImage]?.placement == placement)
        undo.redo()
        #expect(doc.content.pages[page]?.isDone == true)
        #expect(doc.content.pages[page]?.images[storyImage]?.placement == placement)
    }

    @Test func setPageTemplate_undoKeepsALaterDeliveryInAMovedSlot() throws {
        let (doc, undo) = try makeDocument()
        let page = doc.content.book.pageOrder[0]
        perform(doc, undo, .setRichText(page: page, box: story.textBoxes[0].id, text: RichText(plain: "Hi"),
                                        coalescing: false))
        #expect(perform(doc, undo, .setPageTemplate(page: page, templateID: textLeftID)))
        let newBox = try #require(doc.content.templates[textLeftID]?.imageBoxes.first?.id)
        #expect(doc.content.pages[page]?.images[storyImage] == nil)
        let placement = try deliver(doc, page: page, box: newBox)

        undo.undo()
        let restored = try #require(doc.content.pages[page])
        #expect(restored.templateID == story.id)
        #expect(restored.images[storyImage]?.placement == placement, "the delivery survives the undo")
        #expect(restored.text[story.textBoxes[0].id]?.plainText == "Hi")
        undo.redo()
        #expect(doc.content.pages[page]?.images[newBox]?.placement == placement)
        undo.undo()
        undo.undo()
        #expect(doc.content.pages[page]?.text.isEmpty == true, "the text edit undoes as before")
        #expect(doc.content.pages[page]?.images[storyImage]?.placement == placement)
    }

    @Test func setPageTemplate_undoKeepsADeliveryInANewBoxSlotOnRedo() throws {
        let (doc, undo) = try makeDocument()
        let page = doc.content.book.pageOrder[0]
        #expect(perform(doc, undo, .setPageTemplate(page: page, templateID: textOnlyID)))
        #expect(perform(doc, undo, .setPageTemplate(page: page, templateID: textLeftID)))
        let newBox = try #require(doc.content.templates[textLeftID]?.imageBoxes.first?.id)
        let placement = try deliver(doc, page: page, box: newBox)
        undo.undo()
        #expect(doc.content.pages[page]?.templateID == textOnlyID)
        undo.redo()
        #expect(doc.content.pages[page]?.images[newBox]?.placement == placement,
                "the new box's slot comes back with the delivery")
    }
}
