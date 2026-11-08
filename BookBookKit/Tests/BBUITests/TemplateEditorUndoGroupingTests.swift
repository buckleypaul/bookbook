import BBLayout
import BBModel
import BBStore
import Foundation
import Testing
@testable import BBUI

/// Phase 7 follow-ups: undo grouping in `TemplateEditorModel` (bursts, interactions, tokens).
@MainActor
struct TemplateEditorUndoGroupingTests {
    let story = try! Presets.storyTemplate()
    let cover = try! Presets.coverTemplate()

    func make() throws -> (TemplateEditorModel, UndoManager, BoxID) {
        let content = BookContent.makeNew(title: "Test", storyTemplate: story, coverTemplate: cover,
                                          storyPageCount: 1, now: Date(timeIntervalSince1970: 0))
        let url = FileManager.default.temporaryDirectory
            .appending(path: "TemplateEditorUndoGroupingTests-\(UUID().uuidString).bookbook")
        try BookStore.create(content, at: url)
        let document = BookDocument(content: content, store: BookStore(packageURL: url))
        let undo = UndoManager()
        undo.groupsByEvent = false
        document.undoManager = undo
        let model = TemplateEditorModel(document: document)
        step(undo) { model.newTemplate(kind: .single) }
        step(undo) { model.addBox(.image) }
        undo.removeAllActions()
        return (model, undo, try #require(model.selection.first))
    }

    func step(_ undo: UndoManager, _ body: () -> Void) {
        undo.beginUndoGrouping()
        body()
        undo.endUndoGrouping()
    }

    func box(_ model: TemplateEditorModel, _ id: BoxID) -> Box { model.template!.box(id)! }

    @Test func interactionAfterBurst_isItsOwnUndoStep() throws {
        let (model, undo, id) = try make()
        let startX = box(model, id).frame.x
        step(undo) { model.updateContinuously(actionName: "Rotate Box") { $0.boxes[0].rotationDegrees = 10 } }
        // Within 0.6 s: a drag begins.
        step(undo) {
            model.beginInteraction(actionName: "Move Box")
            model.update(actionName: "Move Box") { $0.boxes[0].frame.x = startX + 0.1 }
            model.endInteraction(actionName: "Move Box")
        }
        undo.undo()
        #expect(box(model, id).frame.x == startX)
        #expect(box(model, id).rotationDegrees == 10, "the burst is a separate step")
        undo.undo()
        #expect(box(model, id).rotationDegrees == 0)
    }

    @Test func oneShotUpdateAfterBurst_isItsOwnUndoStep() throws {
        let (model, undo, id) = try make()
        step(undo) { model.updateContinuously(actionName: "Rotate Box") { $0.boxes[0].rotationDegrees = 10 } }
        step(undo) { model.update(actionName: "Nudge Box") { $0.boxes[0].frame.y += 0.1 } }
        undo.undo()
        #expect(box(model, id).rotationDegrees == 10)
        undo.undo()
        #expect(box(model, id).rotationDegrees == 0)
    }

    @Test func staleToken_cannotCloseAnotherGroup() throws {
        let (model, _, _) = try make()
        let first = model.beginInteraction(actionName: "A")
        model.endInteraction(first, actionName: "A")
        let second = model.beginInteraction(actionName: "B")
        model.endInteraction(first, actionName: "A")
        #expect(model.isInteractionOpen(second))
        model.endInteraction(second, actionName: "B")
        #expect(!model.isInteractionOpen(second))
    }

    @Test func undoBeforeFirstEdit_endsTheInteraction() throws {
        let (model, undo, id) = try make()
        step(undo) { model.update(actionName: "Nudge Box") { $0.boxes[0].frame.y += 0.1 } }
        let token = model.beginInteraction(actionName: "Move Box")
        #expect(model.isInteractionOpen(token))
        undo.undo()
        #expect(!model.isInteractionOpen(token))
        // Later edits are ordinary, separately undoable steps.
        step(undo) { model.update(actionName: "Nudge Box") { $0.boxes[0].frame.y += 0.2 } }
        #expect(undo.canUndo)
        undo.undo()
        #expect(box(model, id).rotationDegrees == 0)
    }

    @Test func layerOrder_needsSameKindNeighbour() throws {
        let (model, _, _) = try make()
        #expect(!model.layerOrderHasVisibleEffect, "a lone image box")
        model.addBox(.text(TextBoxStyle()))
        #expect(!model.layerOrderHasVisibleEffect, "text above an image: order has no visible effect")
        model.addBox(.text(TextBoxStyle()))
        #expect(model.layerOrderHasVisibleEffect, "two text boxes")
    }
}
