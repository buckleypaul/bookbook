import AppKit
import BBLayout
import BBModel
import BBStore
import Foundation
import Testing
@testable import BBUI

/// Undo/redo arriving while a template-editor interaction (canvas drag, continuous edit) is
/// still open: the interaction ends and nothing edits or registers afterwards.
@MainActor
struct TemplateUndoInteractionTests {
    let story = try! Presets.storyTemplate()
    let cover = try! Presets.coverTemplate()

    func make() throws -> (TemplateEditorModel, BookDocument, UndoManager) {
        let content = BookContent.makeNew(title: "Test", storyTemplate: story, coverTemplate: cover,
                                          storyPageCount: 1, now: Date(timeIntervalSince1970: 0))
        let url = FileManager.default.temporaryDirectory
            .appending(path: "TemplateUndoInteractionTests-\(UUID().uuidString).bookbook")
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

    /// A blank template with one selected image box; the undo stack is empty afterwards.
    func openWithBox(_ model: TemplateEditorModel, _ undo: UndoManager) throws -> BoxID {
        step(undo) { model.newTemplate(kind: .single) }
        step(undo) { model.addBox(.image) }
        undo.removeAllActions()
        return try #require(model.selection.first)
    }

    func frame(_ model: TemplateEditorModel, _ id: BoxID) -> NormalizedRect { model.template!.box(id)!.frame }

    func mouseEvent(_ type: NSEvent.EventType) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    // MARK: (1) undo during a canvas drag

    @Test func undoDuringCanvasDrag_endsTheDrag() throws {
        let (model, _, undo) = try make()
        let id = try openWithBox(model, undo)
        let start = frame(model, id)
        let canvas = CanvasView(frame: CGRect(x: 0, y: 0, width: 800, height: 800))
        let controller = LayoutEditingController(model: model, imageSource: ImageCache(maxPixelSize: 64) { _ in
            URL(fileURLWithPath: "/dev/null")
        })
        canvas.controller = controller
        let geometry = try #require(model.geometry)
        let centre = CGPoint(x: geometry.trimRect(for: start).midX, y: geometry.trimRect(for: start).midY)

        func down() { controller.mouseDown(with: mouseEvent(.leftMouseDown), at: centre) }
        func drag(_ dx: CGFloat) {
            controller.mouseDragged(with: mouseEvent(.leftMouseDragged), at: CGPoint(x: centre.x + dx, y: centre.y))
        }
        func up(_ dx: CGFloat) {
            controller.mouseUp(with: mouseEvent(.leftMouseUp), at: CGPoint(x: centre.x + dx, y: centre.y))
        }

        // (An empty NSUndoManager group counts as a step, so events that register nothing
        // share one group here.)
        step(undo) {
            down()
            drag(20)
            drag(40)
        }
        #expect(frame(model, id) != start, "the drag moves the box live")
        #expect(undo.canUndo)

        // ⌘Z mid-drag: the move is undone and its group closed.
        undo.undo()
        #expect(frame(model, id) == start)
        #expect(!undo.canUndo)
        #expect(undo.canRedo)

        // The mouse keeps moving, then is released: nothing re-applies (so nothing registers).
        undo.beginUndoGrouping()
        for dx in [60.0, 80, 100] {
            drag(dx)
            #expect(frame(model, id) == start)
        }
        controller.flagsChanged(with: mouseEvent(.leftMouseDragged))
        up(100)
        undo.endUndoGrouping()
        #expect(frame(model, id) == start)
        #expect(model.activeGuides.isEmpty)
        undo.undo()  // the (empty) group above
        #expect(frame(model, id) == start)
        #expect(!undo.canUndo)

        // The next drag works normally and is one step.
        step(undo) {
            down()
            drag(30)
            drag(35)
            up(35)
        }
        #expect(frame(model, id) != start)
        #expect(undo.undoActionName == "Move Box")
        undo.undo()
        #expect(frame(model, id) == start)
        #expect(!undo.canUndo)
    }


    @Test func interactionToken_endsOnUndo() throws {
        let (model, _, undo) = try make()
        let id = try openWithBox(model, undo)
        let start = frame(model, id)
        let token: Int = step(undo) { model.beginInteraction() }
        #expect(model.isInteractionOpen(token))
        step(undo) { model.update(actionName: "Move Box") { $0.boxes[0].frame.x = start.x + 0.1 } }
        undo.undo()
        #expect(!model.isInteractionOpen(token))
        let next: Int = step(undo) { model.beginInteraction() }
        #expect(next != token)
        #expect(model.isInteractionOpen(next))
        step(undo) { model.endInteraction(actionName: "Move Box") }
        #expect(!model.isInteractionOpen(next))
    }

    // MARK: (2) several models on one document

    @Test func secondModel_doesNotStealReplayHandling() async throws {
        let (model, document, undo) = try make()
        let id = try openWithBox(model, undo)
        let start = frame(model, id)
        // SwiftUI may build throwaway models for the same window.
        var throwaway: TemplateEditorModel? = TemplateEditorModel(document: document)
        _ = throwaway
        throwaway = nil

        let token: Int = step(undo) {
            let token = model.beginInteraction()
            _ = TemplateEditorModel(document: document)
            model.update(actionName: "Move Box") { $0.boxes[0].frame.x = start.x + 0.1 }
            return token
        }
        undo.undo()
        #expect(!model.isInteractionOpen(token), "the first model was told its group closed")
        #expect(frame(model, id) == start)

        // A continuous edit on the first model, undone mid-burst: its timer registers nothing.
        step(undo) { model.updateContinuously(actionName: "Rotate Box") { $0.boxes[0].rotationDegrees = 10 } }
        _ = TemplateEditorModel(document: document)
        undo.undo()
        #expect(model.template!.box(id)!.rotationDegrees == 0)
        try await Task.sleep(for: .milliseconds(800))
        #expect(undo.canRedo)
        #expect(!undo.canUndo)
        // And later edits are ordinary single steps again.
        step(undo) { model.update(actionName: "Move Box") { $0.boxes[0].frame.x = start.x + 0.2 } }
        step(undo) { model.update(actionName: "Move Box") { $0.boxes[0].frame.x = start.x + 0.3 } }
        undo.undo()
        #expect(abs(frame(model, id).x - (start.x + 0.2)) < 1e-9)
    }

    // MARK: (4) the group names only its own step

    @Test func endUndoGroup_doesNotRenameANewerStep() throws {
        let (model, document, undo) = try make()
        let id = try openWithBox(model, undo)
        let start = frame(model, id)
        step(undo) {
            document.beginUndoGroup()
            model.update(actionName: "Move Box") { $0.boxes[0].frame.x = start.x + 0.1 }
        }
        #expect(undo.undoActionName == "Move Box", "named by its first edit when it registers")
        // Something outside the document registers a newer step before mouse-up.
        let other = NSObject()
        step(undo) {
            undo.registerUndo(withTarget: other) { _ in }
            undo.setActionName("Other")
        }
        step(undo) {
            // (A registration keeps this group non-empty, so it isn't a step of its own.)
            undo.registerUndo(withTarget: other) { _ in }
            undo.setActionName("Other")
            document.endUndoGroup(actionName: "Nudge Box")
        }
        #expect(undo.undoActionName == "Other")
        undo.undo()
        undo.undo()
        #expect(undo.undoActionName == "Move Box", "the group's step keeps its name")
        undo.undo()
        #expect(frame(model, id) == start)
        #expect(undo.redoActionName == "Nudge Box", "redo carries the final name")
    }

    @Test func endUndoGroup_withNoUndoGroupOpen_addsNoStep() throws {
        // A continuous edit's timer closes its group outside any event: renaming then would
        // start an empty NSUndoManager group, an extra undo step.
        let (model, _, undo) = try make()
        let id = try openWithBox(model, undo)
        let start = frame(model, id)
        step(undo) {
            model.updateContinuously(actionName: "Move Box") { $0.boxes[0].frame.x = start.x + 0.1 }
        }
        model.finishContinuousEdit()  // outside a group: a `setActionName` here would raise
        #expect(undo.undoActionName == "Move Box")
        undo.undo()
        #expect(frame(model, id) == start)
        #expect(!undo.canUndo)
    }

    // MARK: first edit of a bundled preset

    func openOverlayPreset(_ model: TemplateEditorModel, _ document: BookDocument) throws -> (Template, Box) {
        let preset = try #require(Presets.bundledTemplates.first { $0.name == "Full-bleed image with text overlay" })
        #expect(document.content.templates[preset.id] == nil)
        model.open(preset.id)
        let text = try #require(preset.boxes.first { $0.content != .image })
        model.selection = [text.id]
        return (preset, text)
    }

    @Test func presetSendToBack_isOneUndoStep() throws {
        let (model, document, undo) = try make()
        let (preset, text) = try openOverlayPreset(model, document)
        undo.removeAllActions()
        step(undo) { model.moveSelection(.toBack) }
        #expect(document.content.templates[preset.id]?.boxes.first?.id == text.id)
        #expect(undo.undoActionName == "Send to Back")
        undo.undo()
        #expect(document.content.templates[preset.id] == nil)
        #expect(!undo.canUndo, "copy and reorder are one step")
        undo.redo()
        #expect(document.content.templates[preset.id]?.boxes.first?.id == text.id)
        #expect(!undo.canRedo)
    }

    @Test func presetColourBurst_isOneUndoStep() throws {
        let (model, document, undo) = try make()
        let (preset, text) = try openOverlayPreset(model, document)
        undo.removeAllActions()
        func background() -> RGBA? {
            if case let .text(s) = model.template?.box(text.id)?.content { return s.background }
            return nil
        }
        let original = background()
        func pick(_ g: Double) {
            model.updateContinuously(actionName: "Change Background") {
                if let i = $0.boxes.firstIndex(where: { $0.id == text.id }), case .text(var s) = $0.boxes[i].content {
                    s.background = RGBA(red: 0, green: g, blue: 0)
                    $0.boxes[i].content = .text(s)
                }
            }
        }
        // The colour panel fires several changes, each in its own event. Only the first may
        // register; the later ones run outside any NSUndoManager group (with `groupsByEvent`
        // off, a registration there raises, and an empty group would count as a step).
        step(undo) { pick(0.5) }
        pick(0.7)
        pick(0.8)
        model.finishContinuousEdit()
        #expect(background() == RGBA(red: 0, green: 0.8, blue: 0))
        #expect(undo.undoActionName == "Change Background")
        undo.undo()
        #expect(background() == original)
        #expect(document.content.templates[preset.id] == nil)
        #expect(!undo.canUndo)
        undo.redo()
        #expect(background() == RGBA(red: 0, green: 0.8, blue: 0))
        #expect(!undo.canRedo)
    }
}

extension TemplateUndoInteractionTests {
    func step<T>(_ undo: UndoManager, _ body: () -> T) -> T {
        undo.beginUndoGrouping()
        defer { undo.endUndoGrouping() }
        return body()
    }
}
