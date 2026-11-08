import BBLayout
import BBModel
import BBStore
import CoreGraphics
import Foundation
import Testing
@testable import BBUI

/// Phase 6 lane L4: the template editor's model (open, new, duplicate, delete, update,
/// interactions, boxes, layers, align, distribute, nudge).
@MainActor
struct TemplateEditorModelTests {
    let story = try! Presets.storyTemplate()
    let cover = try! Presets.coverTemplate()

    func make(pages: Int = 2) throws -> (TemplateEditorModel, BookDocument, UndoManager) {
        let content = BookContent.makeNew(title: "Test", storyTemplate: story, coverTemplate: cover,
                                          storyPageCount: pages, now: Date(timeIntervalSince1970: 0))
        let url = FileManager.default.temporaryDirectory
            .appending(path: "TemplateEditorModelTests-\(UUID().uuidString).bookbook")
        try BookStore.create(content, at: url)
        let document = BookDocument(content: content, store: BookStore(packageURL: url))
        let undo = UndoManager()
        undo.groupsByEvent = false
        document.undoManager = undo
        return (TemplateEditorModel(document: document), document, undo)
    }

    /// One undo step, like an event-loop turn.
    func step(_ undo: UndoManager, _ body: () -> Void) {
        undo.beginUndoGrouping()
        body()
        undo.endUndoGrouping()
    }

    func openBlank(_ model: TemplateEditorModel, _ undo: UndoManager) -> TemplateID {
        step(undo) { model.newTemplate(kind: .single) }
        return model.templateID!
    }

    func frame(_ model: TemplateEditorModel, _ id: BoxID) -> NormalizedRect { model.template!.box(id)!.frame }

    @Test func openPreset_copiesInWithOneUndoStep() throws {
        let (model, doc, undo) = try make()
        let preset = Presets.bundledTemplates.first { doc.content.templates[$0.id] == nil && $0.kind == .single }!
        step(undo) { model.open(preset.id) }
        #expect(model.templateID == preset.id)
        #expect(doc.content.templates[preset.id] == preset)
        undo.undo()
        #expect(doc.content.templates[preset.id] == nil)
        undo.redo()
        #expect(doc.content.templates[preset.id] == preset)
    }

    @Test func open_unknownIDDoesNothing() throws {
        let (model, _, _) = try make()
        model.open(TemplateID())
        #expect(model.templateID == nil)
    }

    @Test func newTemplate_namesAndOpens() throws {
        let (model, doc, undo) = try make()
        step(undo) { model.newTemplate(kind: .single) }
        #expect(model.template?.name == "New Layout")
        #expect(model.template?.kind == .single)
        step(undo) { model.newTemplate(kind: .spread) }
        #expect(model.template?.name == "New Spread")
        #expect(model.geometry?.isSpread == true)
        #expect(doc.content.templates.count >= 4)
    }

    @Test func duplicate_newIDs() throws {
        let (model, doc, undo) = try make()
        step(undo) { model.duplicate(story.id) }
        let copy = try #require(model.template)
        #expect(copy.id != story.id)
        #expect(copy.name == story.name + " Copy")
        #expect(copy.boxes.count == story.boxes.count)
        #expect(Set(copy.boxes.map(\.id)).isDisjoint(with: story.boxes.map(\.id)))
        #expect(copy.boxes.map(\.frame) == story.boxes.map(\.frame))
        #expect(doc.content.templates[copy.id] != nil)
    }

    @Test func delete_blockedWhileInUse_thenAllowed() throws {
        let (model, doc, undo) = try make()
        #expect(doc.content.pages(using: story.id).count == 2)
        step(undo) { #expect(!model.delete(story.id)) }
        #expect(doc.content.templates[story.id] != nil)
        let id = openBlank(model, undo)
        step(undo) { #expect(model.delete(id)) }
        #expect(doc.content.templates[id] == nil)
        #expect(model.templateID == nil)
        undo.undo()
        #expect(doc.content.templates[id] != nil)
    }

    @Test func update_noOpWhenUnchanged() throws {
        let (model, doc, undo) = try make()
        _ = openBlank(model, undo)
        let before = doc.content.templates
        undo.removeAllActions()
        step(undo) { model.update(actionName: "Nothing") { _ in } }
        step(undo) { model.update(actionName: "Same") { $0.name = $0.name } }
        #expect(undo.undoActionName.isEmpty)
        #expect(doc.content.templates == before)
        step(undo) { model.update(actionName: "Rename Layout") { $0.name = "Hero" } }
        #expect(model.template?.name == "Hero")
        #expect(undo.undoActionName == "Rename Layout")
    }

    @Test func update_withoutOpenTemplateIsNoOp() throws {
        let (model, _, undo) = try make()
        step(undo) { model.update(actionName: "X") { $0.name = "Y" } }
        #expect(undo.undoActionName.isEmpty)
    }

    @Test func interaction_isOneUndoStep() throws {
        let (model, _, undo) = try make()
        _ = openBlank(model, undo)
        step(undo) { model.addBox(.image) }
        let id = try #require(model.selection.first)
        let start = frame(model, id)
        undo.removeAllActions()
        undo.beginUndoGrouping()
        model.beginInteraction()
        for i in 1...5 {
            model.update(actionName: "Move Box") { $0.boxes[0].frame.x = start.x + Double(i) * 0.01 }
        }
        model.activeGuides = [SnapGuide(axis: .vertical, position: 10, span: 0...10)]
        model.endInteraction(actionName: "Move Box")
        undo.endUndoGrouping()
        #expect(model.activeGuides.isEmpty)
        #expect(abs(frame(model, id).x - (start.x + 0.05)) < 1e-9)
        undo.undo()
        #expect(frame(model, id) == start)
        #expect(!undo.canUndo)
        undo.redo()
        #expect(abs(frame(model, id).x - (start.x + 0.05)) < 1e-9)
    }

    @Test func updateContinuously_burstIsOneStep() throws {
        let (model, _, undo) = try make()
        _ = openBlank(model, undo)
        step(undo) { model.addBox(.text(TextBoxStyle())) }
        undo.removeAllActions()
        undo.beginUndoGrouping()
        for p in [4.0, 5, 6] {
            model.updateContinuously(actionName: "Change Padding") {
                if case .text(var s) = $0.boxes[0].content { s.padding = p; $0.boxes[0].content = .text(s) }
            }
        }
        model.finishContinuousEdit()
        undo.endUndoGrouping()
        undo.undo()
        if case let .text(s) = model.template!.boxes[0].content { #expect(s.padding == 0) }
        #expect(!undo.canUndo)
    }

    @Test func addBox_selectsAndCentresInSafeArea() throws {
        let (model, _, undo) = try make()
        _ = openBlank(model, undo)
        step(undo) { model.addBox(.image) }
        let id = try #require(model.selection.first)
        #expect(model.selection.count == 1)
        let geometry = try #require(model.geometry)
        let safe = geometry.pageSafeAreas[0]
        let rect = geometry.trimRect(for: frame(model, id))
        #expect(abs(rect.midX - safe.midX) < 0.001)
        #expect(abs(rect.midY - safe.midY) < 0.001)
        #expect(abs(rect.width - safe.width / 3) < 0.001)
        #expect(abs(rect.height - safe.height / 3) < 0.001)
        #expect(undo.undoActionName == "Add Image Box")
        step(undo) { model.addBox(.text(TextBoxStyle())) }
        #expect(model.template?.boxes.last?.id == model.selection.first)
        #expect(model.template?.boxes.count == 2)
    }

    @Test func layerMoves() throws {
        let (model, _, undo) = try make()
        _ = openBlank(model, undo)
        for _ in 0..<4 { step(undo) { model.addBox(.image) } }
        let ids = model.template!.boxes.map(\.id)
        func order() -> [BoxID] { model.template!.boxes.map(\.id) }
        model.selection = [ids[0]]
        step(undo) { model.moveSelection(.forward) }
        #expect(order() == [ids[1], ids[0], ids[2], ids[3]])
        step(undo) { model.moveSelection(.toFront) }
        #expect(order() == [ids[1], ids[2], ids[3], ids[0]])
        step(undo) { model.moveSelection(.forward) }   // already on top: no-op
        #expect(order() == [ids[1], ids[2], ids[3], ids[0]])
        step(undo) { model.moveSelection(.backward) }
        #expect(order() == [ids[1], ids[2], ids[0], ids[3]])
        step(undo) { model.moveSelection(.toBack) }
        #expect(order() == [ids[0], ids[1], ids[2], ids[3]])
        model.selection = [ids[1], ids[2]]
        step(undo) { model.moveSelection(.toFront) }
        #expect(order() == [ids[0], ids[3], ids[1], ids[2]])
        step(undo) { model.moveSelection(.backward) }
        #expect(order() == [ids[0], ids[1], ids[2], ids[3]])
    }

    @Test func align_multiAndSingle() throws {
        let (model, _, undo) = try make()
        _ = openBlank(model, undo)
        let a = Box(frame: NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), content: .image)
        let b = Box(frame: NormalizedRect(x: 0.5, y: 0.4, width: 0.3, height: 0.1), content: .image)
        step(undo) { model.update(actionName: "Seed") { $0.boxes = [a, b] } }
        model.selection = [a.id, b.id]
        step(undo) { model.align(.left) }
        #expect(frame(model, a.id).x == 0.1)
        #expect(frame(model, b.id).x == 0.1)
        step(undo) { model.align(.bottom) }
        #expect(abs(frame(model, a.id).maxY - 0.5) < 1e-9)
        #expect(abs(frame(model, b.id).maxY - 0.5) < 1e-9)
        // A single box aligns to the page's safe area.
        model.selection = [a.id]
        step(undo) { model.align(.left) }
        let geometry = try #require(model.geometry)
        let safe = geometry.normalizedFrame(for: geometry.pageSafeAreas[0])
        #expect(abs(frame(model, a.id).x - safe.x) < 1e-9)
        #expect(undo.undoActionName == "Align Boxes")
    }

    @Test func distribute_needsThree() throws {
        let (model, _, undo) = try make()
        _ = openBlank(model, undo)
        let boxes = [0.0, 0.2, 0.9].map {
            Box(frame: NormalizedRect(x: $0, y: 0.1, width: 0.1, height: 0.1), content: .image)
        }
        step(undo) { model.update(actionName: "Seed") { $0.boxes = boxes } }
        model.selection = Set(boxes[0..<2].map(\.id))
        undo.removeAllActions()
        step(undo) { model.distribute(.horizontal) }
        #expect(undo.undoActionName.isEmpty)
        model.selection = Set(boxes.map(\.id))
        step(undo) { model.distribute(.horizontal) }
        #expect(abs(frame(model, boxes[1].id).x - 0.45) < 1e-9)
        #expect(frame(model, boxes[0].id).x == 0 && frame(model, boxes[2].id).x == 0.9)
        undo.undo()
        #expect(frame(model, boxes[1].id).x == 0.2)
    }

    @Test func nudge_movesByPointsAsOneStep() throws {
        let (model, _, undo) = try make()
        _ = openBlank(model, undo)
        step(undo) { model.addBox(.image) }
        let id = try #require(model.selection.first)
        let start = frame(model, id)
        let size = try #require(model.geometry).trimSize
        step(undo) { model.nudgeSelection(by: CGVector(dx: 10, dy: -5)) }
        let moved = frame(model, id)
        #expect(abs(moved.x - (start.x + 10 / Double(size.width))) < 1e-9)
        #expect(abs(moved.y - (start.y - 5 / Double(size.height))) < 1e-9)
        #expect(moved.width == start.width)
        undo.undo()
        #expect(frame(model, id) == start)
    }

    @Test func deleteSelection_withUndo() throws {
        let (model, _, undo) = try make()
        _ = openBlank(model, undo)
        step(undo) { model.addBox(.image) }
        step(undo) { model.addBox(.image) }
        let boxes = model.template!.boxes
        model.selection = [boxes[0].id]
        step(undo) { model.deleteSelection() }
        #expect(model.template?.boxes == [boxes[1]])
        #expect(model.selection.isEmpty)
        undo.undo()
        #expect(model.template?.boxes == boxes)
        // Nothing selected: no-op.
        undo.removeAllActions()
        model.selection = []
        step(undo) { model.deleteSelection() }
        #expect(undo.undoActionName.isEmpty)
    }

    @Test func editingAUsedTemplateUpdatesPagesLive() throws {
        let (model, doc, undo) = try make()
        step(undo) { model.open(story.id) }
        let before = doc.content.templates[story.id]!.boxes.count
        step(undo) { model.addBox(.text(TextBoxStyle())) }
        #expect(doc.content.templates[story.id]!.boxes.count == before + 1)
        #expect(doc.content.pages(using: story.id).count == 2)
    }
}
