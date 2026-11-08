import BBModel
import BBStore
import Foundation
import Testing
@testable import BBUI

/// Phase 6 template commands (A §6.3; PD §8.4): add, update and delete with undo, where-used,
/// and one undo step per drag.
@MainActor
struct TemplateCommandTests {
    let story = try! Presets.storyTemplate()
    let cover = try! Presets.coverTemplate()

    func makeDocument(pages: Int = 2) throws -> (BookDocument, UndoManager) {
        let content = BookContent.makeNew(title: "Test", storyTemplate: story, coverTemplate: cover,
                                          storyPageCount: pages, now: Date(timeIntervalSince1970: 0))
        let url = FileManager.default.temporaryDirectory
            .appending(path: "TemplateCommandTests-\(UUID().uuidString).bookbook")
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

    func custom(_ boxes: [Box] = []) -> Template {
        Template(name: "Custom", kind: .single, boxes: boxes)
    }

    func imageBox(x: Double = 0) -> Box {
        Box(frame: NormalizedRect(x: x, y: 0, width: 0.5, height: 0.5), content: .image)
    }

    // MARK: where-used

    @Test func pagesUsing_coverFirstThenReadingOrder() throws {
        var content = BookContent.makeNew(title: "T", storyTemplate: story, coverTemplate: cover,
                                          storyPageCount: 3, now: Date(timeIntervalSince1970: 0))
        #expect(content.pages(using: story.id) == content.book.pageOrder)
        #expect(content.pages(using: cover.id) == [content.book.coverPageID])
        #expect(content.pages(using: TemplateID()).isEmpty)
        // Reading order follows pageOrder, not ID order.
        content.book.pageOrder.reverse()
        #expect(content.pages(using: story.id) == content.book.pageOrder)
        // The cover is listed first when it shares a template.
        content.pages[content.book.coverPageID]?.templateID = story.id
        #expect(content.pages(using: story.id) == [content.book.coverPageID] + content.book.pageOrder)
    }

    // MARK: add / update / delete

    @Test func addTemplate_undoRedo_andDuplicateIgnored() throws {
        let (doc, undo) = try makeDocument()
        let t = custom()
        #expect(perform(doc, undo, .addTemplate(t)))
        #expect(doc.content.templates[t.id] == t)
        #expect(!doc.perform(.addTemplate(t)), "existing ID is ignored")
        undo.undo()
        #expect(doc.content.templates[t.id] == nil)
        undo.redo()
        #expect(doc.content.templates[t.id] == t)
    }

    @Test func updateTemplate_undoRedo_andRejections() throws {
        let (doc, undo) = try makeDocument()
        var t = custom([imageBox()])
        perform(doc, undo, .addTemplate(t))
        let original = t
        t.boxes[0].rotationDegrees = 5
        #expect(perform(doc, undo, .updateTemplate(t, actionName: "Rotate Box")))
        #expect(undo.undoActionName == "Rotate Box")
        #expect(doc.content.templates[t.id] == t)
        undo.undo()
        #expect(doc.content.templates[t.id] == original)
        undo.redo()
        #expect(doc.content.templates[t.id] == t)

        #expect(!doc.perform(.updateTemplate(t, actionName: "Same")), "unchanged is a no-op")
        var other = t
        other.id = TemplateID()
        #expect(!doc.perform(.updateTemplate(other, actionName: "Unknown")))
        var kind = t
        kind.kind = .spread
        kind.name = "x"
        #expect(!doc.perform(.updateTemplate(kind, actionName: "Kind")))
        #expect(doc.content.templates[t.id] == t)
    }

    @Test func deleteTemplate_blockedWhileInUse_thenUndoRestores() throws {
        let (doc, undo) = try makeDocument()
        #expect(!doc.perform(.deleteTemplate(story.id)), "pages use it")
        #expect(doc.content.templates[story.id] != nil)
        let t = custom()
        perform(doc, undo, .addTemplate(t))
        #expect(perform(doc, undo, .deleteTemplate(t.id)))
        #expect(doc.content.templates[t.id] == nil)
        undo.undo()
        #expect(doc.content.templates[t.id] == t)
        undo.redo()
        #expect(doc.content.templates[t.id] == nil)
        // In use again once a page switches to it.
        let page = doc.content.book.pageOrder[0]
        perform(doc, undo, .addTemplate(t))
        perform(doc, undo, .setPageTemplate(page: page, templateID: t.id))
        #expect(!doc.perform(.deleteTemplate(t.id)))
    }

    @Test func updateTemplate_newImageBoxGetsSessionsAndSlotsOnUsingPages() throws {
        let (doc, undo) = try makeDocument(pages: 2)
        var t = story
        let added = imageBox(x: 0.5)
        t.boxes.append(added)
        #expect(perform(doc, undo, .updateTemplate(t, actionName: "Add Image Box")))
        for pageID in doc.content.book.pageOrder {
            let slot = try #require(doc.content.pages[pageID]?.images[added.id])
            let session = try #require(doc.content.sessions[slot.sessionID])
            #expect(session.owner == .pageBox(pageID, added.id))
        }
        let coverPage = try #require(doc.content.coverPage)
        #expect(coverPage.images[added.id] == nil, "the cover doesn't use the template")

        // Removing the box keeps the slot (harmless, restored by undo).
        let first = doc.content.book.pageOrder[0]
        let slotBefore = doc.content.pages[first]?.images[added.id]
        var removed = t
        removed.boxes.removeAll { $0.id == added.id }
        #expect(perform(doc, undo, .updateTemplate(removed, actionName: "Delete Box")))
        #expect(doc.content.pages[first]?.images[added.id] == slotBefore)
        // Re-adding reuses the existing slot.
        #expect(perform(doc, undo, .updateTemplate(t, actionName: "Add Image Box")))
        #expect(doc.content.pages[first]?.images[added.id] == slotBefore)
    }

    // MARK: undo groups

    @Test func undoGroup_perDrag_oneStep() throws {
        let (doc, undo) = try makeDocument()
        var t = custom([imageBox()])
        perform(doc, undo, .addTemplate(t))
        let original = t
        undo.beginUndoGrouping()
        doc.beginUndoGroup()
        for i in 1...5 {
            t.boxes[0].frame.x = Double(i) * 0.05
            #expect(doc.perform(.updateTemplate(t, actionName: "Move Box")))
            #expect(doc.content.templates[t.id] == t, "live while dragging")
        }
        doc.endUndoGroup(actionName: "Move Box")
        undo.endUndoGrouping()
        #expect(undo.undoActionName == "Move Box")

        undo.undo()
        #expect(doc.content.templates[t.id] == original)
        #expect(undo.canUndo, "the add is still there")
        undo.redo()
        #expect(doc.content.templates[t.id] == t)
        undo.undo()
        #expect(doc.content.templates[t.id] == original)
        undo.undo()
        #expect(doc.content.templates[t.id] == nil)
    }

    @Test func undoGroup_emptyRegistersNothing() throws {
        // (No surrounding NSUndoManager group: an empty one would itself count as an undo step.)
        let (doc, undo) = try makeDocument()
        doc.beginUndoGroup()
        doc.endUndoGroup(actionName: "Move Box")
        #expect(!undo.canUndo)
        // A group whose only edit is a no-op also registers nothing.
        let t = custom()
        perform(doc, undo, .addTemplate(t))
        undo.removeAllActions()
        doc.beginUndoGroup()
        #expect(!doc.perform(.updateTemplate(t, actionName: "Move Box")))
        doc.endUndoGroup(actionName: "Move Box")
        #expect(!undo.canUndo)
        // Unmatched end is harmless.
        doc.endUndoGroup(actionName: "x")
    }

    @Test func undoGroup_closesTypingStep() throws {
        let (doc, undo) = try makeDocument(pages: 1)
        let page = doc.content.book.pageOrder[0]
        let box = story.textBoxes[0].id
        perform(doc, undo, .setRichText(page: page, box: box, text: RichText(plain: "a")))
        doc.beginUndoGroup()
        doc.endUndoGroup(actionName: "Move Box")
        // Typing after a group starts a new step instead of joining the earlier one.
        perform(doc, undo, .setRichText(page: page, box: box, text: RichText(plain: "ab")))
        undo.undo()
        #expect(doc.content.pages[page]?.text[box] == RichText(plain: "a"))
    }
}
