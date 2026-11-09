import BBLayout
import BBModel
import BBStore
import CoreGraphics
import Foundation
import Testing
@testable import BBUI

/// Phase 16b: a bleed edge taken off a spread's fold stops bleeding in the same edit (#64);
/// new boxes cascade instead of stacking (#54a).
@MainActor
struct Phase16bLayoutEditingTests {
    let story = try! Presets.storyTemplate()
    let cover = try! Presets.coverTemplate()

    func make(bleed: Bool = true) throws -> (TemplateEditorModel, UndoManager) {
        var content = BookContent.makeNew(title: "Test", storyTemplate: story, coverTemplate: cover,
                                          storyPageCount: 1, now: Date(timeIntervalSince1970: 0))
        content.style.pageSetup.bleedEnabled = bleed
        content.style.pageSetup.bleedAmount = 9
        let url = FileManager.default.temporaryDirectory
            .appending(path: "Phase16bLayoutEditingTests-\(UUID().uuidString).bookbook")
        try BookStore.create(content, at: url)
        let document = BookDocument(content: content, store: BookStore(packageURL: url))
        let undo = UndoManager()
        undo.groupsByEvent = false
        document.undoManager = undo
        return (TemplateEditorModel(document: document), undo)
    }

    func step(_ undo: UndoManager, _ body: () -> Void) {
        undo.beginUndoGrouping()
        body()
        undo.endUndoGrouping()
    }

    /// A spread with one full-bleed image box covering the right-hand page (leading edge on the fold).
    func rightHalfBox(_ model: TemplateEditorModel, _ undo: UndoManager) -> BoxID {
        step(undo) { model.newTemplate(kind: .spread) }
        let box = Box(frame: NormalizedRect(x: 0.5, y: 0, width: 0.5, height: 1), bleedEdges: .all, content: .image)
        step(undo) { model.update(actionName: "Add") { $0.boxes = [box] } }
        model.selection = [box.id]
        return box.id
    }

    // MARK: #64

    @Test func foldEdges_onlyOnASpreadAndOnlyAtTheFold() {
        var setup = PageSetup(trimSize: PointSize(width: 600, height: 800), orientation: .portrait,
                              margins: EdgeInsetsPt(top: 36, leading: 36, bottom: 36, trailing: 36))
        setup.bleedEnabled = true
        let spread = PageGeometry(drawSetup: setup, isSpread: true)
        let single = PageGeometry(drawSetup: setup, isSpread: false)
        let left = Box(frame: NormalizedRect(x: 0, y: 0, width: 0.5, height: 1), bleedEdges: .all, content: .image)
        let right = Box(frame: NormalizedRect(x: 0.5, y: 0, width: 0.5, height: 1), bleedEdges: .all, content: .image)
        #expect(LayoutEditingMath.foldEdges(of: left, geometry: spread) == .trailing)
        #expect(LayoutEditingMath.foldEdges(of: right, geometry: spread) == .leading)
        #expect(LayoutEditingMath.foldEdges(of: right, geometry: single).isEmpty)
        var noBleed = right
        noBleed.bleedEdges = [.top]
        #expect(LayoutEditingMath.foldEdges(of: noBleed, geometry: spread).isEmpty)
    }

    @Test func bleedEdges_dropsAnEdgeMovedOffTheFold_keepsOthers() {
        var setup = PageSetup(trimSize: PointSize(width: 600, height: 800), orientation: .portrait,
                              margins: EdgeInsetsPt(top: 36, leading: 36, bottom: 36, trailing: 36))
        setup.bleedEnabled = true
        let spread = PageGeometry(drawSetup: setup, isSpread: true)
        var box = Box(frame: NormalizedRect(x: 0.5, y: 0, width: 0.5, height: 1), bleedEdges: .all, content: .image)
        let before = LayoutEditingMath.foldEdges(of: box, geometry: spread)
        // Still on the fold: unchanged.
        #expect(LayoutEditingMath.bleedEdges(of: box, foldEdgesBefore: before, geometry: spread) == .all)
        box.frame.x = 0.52
        #expect(LayoutEditingMath.bleedEdges(of: box, foldEdgesBefore: before, geometry: spread)
                == [.top, .bottom, .trailing])
        // An edge that wasn't on the fold before is never dropped.
        #expect(LayoutEditingMath.bleedEdges(of: box, foldEdgesBefore: [], geometry: spread) == .all)
    }

    @Test func nudgeOffTheFold_bleedDoesNotReappear() throws {
        let (model, undo) = try make()
        let id = rightHalfBox(model, undo)
        let geometry = try #require(model.geometry)
        let foldX = geometry.foldX
        #expect(geometry.renderRect(for: model.template!.box(id)!).minX == foldX, "suppressed at the fold")
        step(undo) { model.nudgeSelection(by: CGVector(dx: 10, dy: 0)) }
        let moved = try #require(model.template?.box(id))
        #expect(moved.bleedEdges == [.top, .bottom, .trailing])
        #expect(abs(geometry.renderRect(for: moved).minX - (foldX + 10)) < 0.001, "no 9 pt jump")
        undo.undo()
        #expect(model.template?.box(id)?.bleedEdges == .all, "undo restores the edge with the frame")
        #expect(model.template?.box(id)?.frame.x == 0.5)
    }

    @Test func alignOffTheFold_dropsTheEdgeToo() throws {
        let (model, undo) = try make()
        let id = rightHalfBox(model, undo)
        let other = Box(frame: NormalizedRect(x: 0.3, y: 0.1, width: 0.1, height: 0.1), content: .image)
        step(undo) { model.update(actionName: "Add") { $0.boxes.append(other) } }
        model.selection = [id, other.id]
        step(undo) { model.align(.left) }
        let box = try #require(model.template?.box(id))
        #expect(abs(box.frame.x - 0.3) < 0.0001)
        #expect(box.bleedEdges == [.top, .bottom, .trailing])
    }

    @Test func nudgeAlongTheFold_keepsTheEdge() throws {
        let (model, undo) = try make()
        let id = rightHalfBox(model, undo)
        step(undo) { model.nudgeSelection(by: CGVector(dx: 0, dy: 10)) }
        #expect(model.template?.box(id)?.bleedEdges == .all)
    }

    @Test func frameFieldOffTheFold_dropsTheEdgeToo() throws {
        let (model, undo) = try make()
        let id = rightHalfBox(model, undo)
        // As the inspector's X field does: a plain `update` that sets the frame.
        step(undo) { model.update(actionName: "Move Box") { $0.boxes[0].frame.x = 0.55 } }
        #expect(model.template?.box(id)?.bleedEdges == [.top, .bottom, .trailing])
        // Toggling bleed without moving the frame is never touched.
        step(undo) { model.update(actionName: "Bleed") { $0.boxes[0].bleedEdges = .all } }
        #expect(model.template?.box(id)?.bleedEdges == .all)
    }

    @Test func dragStepsOffAndBackOntoTheFold_edgeStaysDropped() throws {
        let (model, undo) = try make()
        let id = rightHalfBox(model, undo)
        // A drag's continuous updates inside one interaction, as `LayoutEditingController` makes them.
        step(undo) {
            let token = model.beginInteraction(actionName: "Move Box")
            model.update(actionName: "Move Box") { $0.boxes[0].frame.y = 0.01 }
            #expect(model.template?.box(id)?.bleedEdges == .all, "still on the fold")
            model.update(actionName: "Move Box") { $0.boxes[0].frame.x = 0.6 }
            model.update(actionName: "Move Box") { $0.boxes[0].frame.x = 0.5 }
            model.endInteraction(token, actionName: "Move Box")
        }
        #expect(model.template?.box(id)?.bleedEdges == [.top, .bottom, .trailing])
    }

    // MARK: #54a

    @Test func newBoxes_cascadeInsteadOfStacking() throws {
        let (model, undo) = try make(bleed: false)
        step(undo) { model.newTemplate(kind: .single) }
        for _ in 0..<3 { step(undo) { model.addBox(.image) } }
        let geometry = try #require(model.geometry)
        let rects = try #require(model.template?.boxes).map { geometry.trimRect(for: $0.frame) }
        #expect(rects.count == 3)
        let step = TemplateEditorModel.newBoxCascadeStep
        #expect(abs(rects[1].minX - rects[0].minX - step) < 0.001)
        #expect(abs(rects[1].minY - rects[0].minY - step) < 0.001)
        #expect(abs(rects[2].minX - rects[1].minX - step) < 0.001)
        #expect(Set(rects.map { "\($0.minX),\($0.minY)" }).count == 3, "no two boxes at the same spot")
    }

    @Test func newBoxRect_staysInTheSafeArea() {
        let safe = CGRect(x: 36, y: 36, width: 540, height: 720)
        let size = CGSize(width: 180, height: 240)
        var existing: [CGRect] = []
        for _ in 0..<40 {
            let rect = TemplateEditorModel.newBoxRect(size: size, safe: safe, existing: existing)
            #expect(safe.contains(rect), "clamped to the safe area")
            existing.append(rect)
        }
        // The first is centred.
        #expect(existing[0].midX == safe.midX && existing[0].midY == safe.midY)
    }
}
