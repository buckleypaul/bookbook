import AppKit
import BBLayout
import BBModel
import BBStore
import CryptoKit
import Foundation
import Testing
@testable import BBUI

/// Phase 8 pan/zoom crop (A §7.5): `BookCommand.setCrop`, `CropMath`, and the page canvas's
/// drag and zoom gestures (one undo step each).
@MainActor
struct CropCommandTests {
    let story = try! Presets.storyTemplate()                        // image (top), text
    let cover = try! Presets.coverTemplate()

    var imageBox: Box { story.imageBoxes[0] }

    func makeDocument() throws -> (BookDocument, UndoManager) {
        let content = BookContent.makeNew(title: "Test", storyTemplate: story, coverTemplate: cover,
                                          storyPageCount: 1, now: Date(timeIntervalSince1970: 0))
        let url = FileManager.default.temporaryDirectory
            .appending(path: "CropCommandTests-\(UUID().uuidString).bookbook")
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

    /// Adds a version (non-undoable) and places it (undoable), then clears the undo stack.
    func placeVersion(_ doc: BookDocument, _ undo: UndoManager, size: PixelSize = PixelSize(width: 1024, height: 1024))
        throws -> (PageID, VersionID) {
        let page = doc.content.book.pageOrder[0]
        let sha = SHA256.hash(data: Data(UUID().uuidString.utf8)).map { String(format: "%02x", $0) }.joined()
        let version = Version(image: ImageRef(sha256: sha, contentType: "public.png"), pixelSize: size,
                              source: .generated, createdAt: Date(timeIntervalSince1970: 1))
        let sessionID = try #require(doc.content.pages[page]?.images[imageBox.id]?.sessionID)
        doc.performIrreversible { content in
            content.sessions[sessionID]?.versions.append(version)
            return DirtySet(sessions: [sessionID])
        }
        #expect(perform(doc, undo, .chooseVersion(page: page, box: imageBox.id, version: version.id)))
        undo.removeAllActions()
        return (page, version.id)
    }

    func placement(_ doc: BookDocument, _ page: PageID) -> ImagePlacement? {
        doc.content.pages[page]?.images[imageBox.id]?.placement
    }

    func boxRect(_ doc: BookDocument) -> CGRect {
        PageGeometry(setup: doc.content.style.pageSetup, kind: story.kind).renderRect(for: imageBox)
    }

    // MARK: setCrop

    @Test func setCrop_undoRedo_keepsBaselineAndAspect() throws {
        let (doc, undo) = try makeDocument()
        let (page, _) = try placeVersion(doc, undo)
        let slotBefore = try #require(doc.content.pages[page]?.images[imageBox.id])

        #expect(perform(doc, undo, .setCrop(page: page, box: imageBox.id, zoom: 2, center: NormalizedPoint(x: 0.4, y: 0.45))))
        #expect(undo.undoActionName == "Adjust Crop")
        let cropped = try #require(placement(doc, page))
        #expect(cropped.zoom == 2)
        #expect(abs(cropped.center.x - 0.4) < 1e-9 && abs(cropped.center.y - 0.45) < 1e-9)
        #expect(cropped.boxAspectWhenPlaced == slotBefore.placement?.boxAspectWhenPlaced)
        #expect(cropped.versionID == slotBefore.placement?.versionID)
        #expect(doc.content.pages[page]?.images[imageBox.id]?.acknowledged == slotBefore.acknowledged)

        undo.undo()
        #expect(doc.content.pages[page]?.images[imageBox.id] == slotBefore)
        undo.redo()
        #expect(placement(doc, page) == cropped)
    }

    @Test func setCrop_clampsZoomAndCentre() throws {
        let (doc, undo) = try makeDocument()
        let (page, _) = try placeVersion(doc, undo)
        let rect = boxRect(doc)
        #expect(rect.width > rect.height, "a wide box: a square image overflows vertically at zoom 1")

        // Zoom 1: no horizontal slack, so x is forced to the middle; y may move only so far.
        #expect(perform(doc, undo, .setCrop(page: page, box: imageBox.id, zoom: 0.25, center: NormalizedPoint(x: 0, y: 0))))
        var p = try #require(placement(doc, page))
        #expect(p.zoom == 1)
        #expect(abs(p.center.x - 0.5) < 1e-9)
        let minY = Double(rect.height / rect.width) / 2           // the box's half-height in image units
        #expect(abs(p.center.y - minY) < 1e-9)

        #expect(perform(doc, undo, .setCrop(page: page, box: imageBox.id, zoom: 100, center: NormalizedPoint(x: 2, y: -1))))
        p = try #require(placement(doc, page))
        #expect(p.zoom == CropMath.maximumZoom)
        #expect(p.center.x < 1 && p.center.x > 0.9)
        #expect(p.center.y > 0 && p.center.y < 0.1)

        // The stored crop draws exactly the clamped rect.
        let image = CGSize(width: 1024, height: 1024)
        let drawn = PageGeometry.imageRect(imageSize: image, boxRect: rect, placement: p)
        #expect(drawn.minX <= rect.minX + 1e-6 && drawn.maxX >= rect.maxX - 1e-6)
        #expect(drawn.minY <= rect.minY + 1e-6 && drawn.maxY >= rect.maxY - 1e-6)
    }

    @Test func setCrop_noOpWhenUnchangedOrNothingPlaced() throws {
        let (doc, undo) = try makeDocument()
        let page = doc.content.book.pageOrder[0]
        #expect(!doc.perform(.setCrop(page: page, box: imageBox.id, zoom: 2, center: .center)), "empty box")
        _ = try placeVersion(doc, undo)
        #expect(!doc.perform(.setCrop(page: page, box: imageBox.id, zoom: 1, center: .center)), "already so")
        #expect(!doc.perform(.setCrop(page: page, box: imageBox.id, zoom: 0.5, center: NormalizedPoint(x: 0.1, y: 0.5))),
                "clamps to the current crop")
        #expect(!undo.canUndo)
        let text = story.textBoxes[0].id
        #expect(!doc.perform(.setCrop(page: page, box: text, zoom: 2, center: .center)), "not an image box")
    }

    @Test func setCrop_undoAfterANewVersionIsPlacedLeavesItAlone() throws {
        let (doc, undo) = try makeDocument()
        let (page, _) = try placeVersion(doc, undo)
        perform(doc, undo, .setCrop(page: page, box: imageBox.id, zoom: 3, center: .center))
        // An AI delivery places another version (not undoable).
        let other = try #require(doc.content.pages[page]?.images[imageBox.id])
        let newPlacement = ImagePlacement(versionID: VersionID(), boxAspectWhenPlaced: 1)
        doc.performIrreversible { content in
            content.pages[page]?.images[imageBox.id]?.placement = newPlacement
            return DirtySet(pages: [page])
        }
        undo.undo()
        #expect(placement(doc, page) == newPlacement, "the crop's undo is for its own version only")
        _ = other
    }

    @Test func undoGroup_oneStepPerDrag() throws {
        let (doc, undo) = try makeDocument()
        let (page, _) = try placeVersion(doc, undo)
        let original = try #require(placement(doc, page))
        undo.beginUndoGrouping()
        doc.beginUndoGroup(actionName: BookCommand.cropActionName)
        for i in 1...5 {
            #expect(doc.perform(.setCrop(page: page, box: imageBox.id, zoom: 1 + Double(i) * 0.2, center: .center)))
        }
        doc.endUndoGroup(actionName: BookCommand.cropActionName)
        undo.endUndoGrouping()
        #expect(abs((placement(doc, page)?.zoom ?? 0) - 2) < 1e-9)
        #expect(undo.undoActionName == "Adjust Crop")

        undo.undo()
        #expect(placement(doc, page) == original)
        #expect(!undo.canUndo, "one step for the whole drag")
        undo.redo()
        #expect(abs((placement(doc, page)?.zoom ?? 0) - 2) < 1e-9)
    }

    // MARK: CropMath

    @Test func pan_storedPlacementRendersThePannedRect_asExportDraws() throws {
        let (doc, undo) = try makeDocument()
        let (page, _) = try placeVersion(doc, undo, size: PixelSize(width: 1536, height: 1024))
        perform(doc, undo, .setCrop(page: page, box: imageBox.id, zoom: 2, center: .center))
        let start = try #require(placement(doc, page))
        let rect = boxRect(doc)
        let image = CGSize(width: 1536, height: 1024)
        let before = PageGeometry.imageRect(imageSize: image, boxRect: rect, placement: start)

        let delta = CGSize(width: 12, height: -7)
        let crop = CropMath.panned(start, by: delta, imageSize: image, boxRect: rect)
        #expect(perform(doc, undo, .setCrop(page: page, box: imageBox.id, zoom: crop.zoom, center: crop.center)))
        let stored = try #require(placement(doc, page))
        // `PageRenderer` (screen and PDF export) draws `imageRect` of the stored placement.
        let after = PageGeometry.imageRect(imageSize: image, boxRect: rect, placement: stored)
        #expect(abs(after.minX - (before.minX + 12)) < 1e-6)
        #expect(abs(after.minY - (before.minY - 7)) < 1e-6)
        #expect(abs(after.width - before.width) < 1e-6)
    }

    @Test func pan_clampsAtTheEdge() {
        let rect = CGRect(x: 0, y: 0, width: 200, height: 100)
        let image = CGSize(width: 100, height: 100)
        let start = ImagePlacement(versionID: VersionID(), boxAspectWhenPlaced: 2)
        let crop = CropMath.panned(start, by: CGSize(width: 0, height: 1000), imageSize: image, boxRect: rect)
        let drawn = PageGeometry.imageRect(imageSize: image, boxRect: rect,
                                           placement: ImagePlacement(versionID: start.versionID, zoom: crop.zoom,
                                                                     center: crop.center, boxAspectWhenPlaced: 2))
        #expect(drawn.minY == 0, "the image's top edge stops at the box's top")
        #expect(abs(crop.center.y - 0.25) < 1e-9)
    }

    @Test func zoom_keepsThePointUnderTheAnchor() {
        let rect = CGRect(x: 10, y: 20, width: 200, height: 100)
        let image = CGSize(width: 400, height: 200)
        let start = ImagePlacement(versionID: VersionID(), zoom: 2, center: .center, boxAspectWhenPlaced: 2)
        let anchor = CGPoint(x: 60, y: 50)
        let before = PageGeometry.imageRect(imageSize: image, boxRect: rect, placement: start)
        let u = (anchor.x - before.minX) / before.width, v = (anchor.y - before.minY) / before.height
        let crop = CropMath.zoomed(start, by: 1.5, around: anchor, imageSize: image, boxRect: rect)
        #expect(abs(crop.zoom - 3) < 1e-9)
        let after = PageGeometry.imageRect(imageSize: image, boxRect: rect,
                                           placement: ImagePlacement(versionID: start.versionID, zoom: crop.zoom,
                                                                     center: crop.center, boxAspectWhenPlaced: 2))
        #expect(abs(after.minX + u * after.width - anchor.x) < 1e-6)
        #expect(abs(after.minY + v * after.height - anchor.y) < 1e-6)

        let out = CropMath.zoomed(start, by: 0.01, around: anchor, imageSize: image, boxRect: rect)
        #expect(out.zoom == 1 && abs(out.center.x - 0.5) < 1e-9 && abs(out.center.y - 0.5) < 1e-9)
    }

    @Test func unrotated_invertsTheCanvasRotation() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 50)
        let p = CropMath.unrotated(CGPoint(x: 50, y: 75), about: rect, degrees: 90)
        // Rotating (50, 75) back by 90° about (50, 25) gives (100, 25).
        #expect(abs(p.x - 100) < 1e-9 && abs(p.y - 25) < 1e-9)
    }

    @Test func unrotatedVector_signConventions() {
        // Positive degrees are clockwise on screen (y down): a page vector pointing down the page
        // is the +x axis of a box rotated 90°.
        let down = CropMath.unrotated(CGSize(width: 0, height: 10), degrees: 90)
        #expect(abs(down.width - 10) < 1e-9 && abs(down.height) < 1e-9)
        let right = CropMath.unrotated(CGSize(width: 10, height: 0), degrees: 90)
        #expect(abs(right.width) < 1e-9 && abs(right.height + 10) < 1e-9)
        // Negating the angle rotates the other way (what the resize maths uses to map back).
        let back = CropMath.unrotated(CGSize(width: 10, height: 0), degrees: -90)
        #expect(abs(back.width) < 1e-9 && abs(back.height - 10) < 1e-9)
        // Zero and non-finite angles leave the vector alone.
        #expect(CropMath.unrotated(CGSize(width: 3, height: 4), degrees: 0) == CGSize(width: 3, height: 4))
        #expect(CropMath.unrotated(CGSize(width: 3, height: 4), degrees: .nan) == CGSize(width: 3, height: 4))
        // Matches the point form about a rect's centre.
        let rect = CGRect(x: 10, y: 20, width: 40, height: 30)
        let p = CropMath.unrotated(CGPoint(x: 37, y: 41), about: rect, degrees: 33)
        let v = CropMath.unrotated(CGSize(width: 37 - rect.midX, height: 41 - rect.midY), degrees: 33)
        #expect(abs(p.x - (rect.midX + v.width)) < 1e-9 && abs(p.y - (rect.midY + v.height)) < 1e-9)
    }

    // MARK: Canvas gestures

    final class NoImages: PageImageSource {
        func image(for ref: ImageRef) -> CGImage? { nil }
    }

    func mouseEvent(_ type: NSEvent.EventType, clickCount: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                           context: nil, eventNumber: 0, clickCount: clickCount, pressure: 1)!
    }

    /// A page canvas wired to `doc` as `PageCanvas` wires it, with the image box selected.
    func canvas(_ doc: BookDocument, page: PageID, selected: BoxID?) -> (CanvasView, PlacementController, Counter) {
        let view = CanvasView(frame: CGRect(x: 0, y: 0, width: 800, height: 800))
        let controller = PlacementController()
        view.controller = controller
        let counter = Counter()
        controller.onBeginCrop = { closed in
            counter.begins += 1
            doc.beginUndoGroup(actionName: BookCommand.cropActionName, onClosedByReplay: closed)
        }
        controller.onCrop = { page, box, zoom, center in
            counter.crops += 1
            doc.perform(.setCrop(page: page, box: box, zoom: zoom, center: center))
        }
        controller.onEndCrop = {
            counter.ends += 1
            doc.endUndoGroup(actionName: BookCommand.cropActionName)
        }
        controller.update(content: doc.content, pageID: page, selectedImageBox: selected, imageSource: NoImages())
        return (view, controller, counter)
    }

    @MainActor final class Counter {
        var begins = 0, crops = 0, ends = 0
    }

    @Test func canvasDrag_pansAsOneUndoStep() throws {
        let (doc, undo) = try makeDocument()
        let (page, _) = try placeVersion(doc, undo)
        perform(doc, undo, .setCrop(page: page, box: imageBox.id, zoom: 2, center: .center))
        undo.removeAllActions()
        let original = try #require(placement(doc, page))
        let (_, controller, counter) = canvas(doc, page: page, selected: imageBox.id)
        let rect = boxRect(doc)
        let centre = CGPoint(x: rect.midX, y: rect.midY)

        undo.beginUndoGrouping()
        controller.mouseDown(with: mouseEvent(.leftMouseDown), at: centre)
        for dx in [5.0, 10, 15, 20] {
            controller.mouseDragged(with: mouseEvent(.leftMouseDragged), at: CGPoint(x: centre.x + dx, y: centre.y))
        }
        controller.mouseUp(with: mouseEvent(.leftMouseUp), at: CGPoint(x: centre.x + 20, y: centre.y))
        undo.endUndoGrouping()

        #expect(counter.begins == 1 && counter.ends == 1 && counter.crops == 4)
        let image = CGSize(width: 1024, height: 1024)
        let before = PageGeometry.imageRect(imageSize: image, boxRect: rect, placement: original)
        let after = PageGeometry.imageRect(imageSize: image, boxRect: rect, placement: try #require(placement(doc, page)))
        #expect(abs(after.minX - before.minX - 20) < 1e-6, "the image follows the pointer")
        undo.undo()
        #expect(placement(doc, page) == original)
        #expect(!undo.canUndo)
    }

    @Test func canvasClick_withoutDrag_registersNothing_andUnselectedBoxDoesNotPan() throws {
        let (doc, undo) = try makeDocument()
        let (page, _) = try placeVersion(doc, undo)
        let rect = boxRect(doc)
        let centre = CGPoint(x: rect.midX, y: rect.midY)

        // A plain click on the selected box: no crop.
        var (_, controller, counter) = canvas(doc, page: page, selected: imageBox.id)
        controller.mouseDown(with: mouseEvent(.leftMouseDown), at: centre)
        controller.mouseUp(with: mouseEvent(.leftMouseUp), at: centre)
        #expect(counter.begins == 0 && counter.crops == 0 && counter.ends == 0)

        // Dragging a box that wasn't selected only selects it.
        (_, controller, counter) = canvas(doc, page: page, selected: nil)
        var selected: BoxID?
        controller.onSelectImageBox = { selected = $0 }
        controller.mouseDown(with: mouseEvent(.leftMouseDown), at: centre)
        controller.mouseDragged(with: mouseEvent(.leftMouseDragged), at: CGPoint(x: centre.x + 30, y: centre.y))
        controller.mouseUp(with: mouseEvent(.leftMouseUp), at: CGPoint(x: centre.x + 30, y: centre.y))
        #expect(selected == imageBox.id)
        #expect(counter.begins == 0 && counter.crops == 0)
        #expect(!undo.canUndo)
    }

    @Test func canvasPinch_zoomsAsOneUndoStep() throws {
        let (doc, undo) = try makeDocument()
        let (page, _) = try placeVersion(doc, undo)
        let original = try #require(placement(doc, page))
        let (_, controller, counter) = canvas(doc, page: page, selected: imageBox.id)
        let rect = boxRect(doc)
        let centre = CGPoint(x: rect.midX, y: rect.midY)

        undo.beginUndoGrouping()
        #expect(controller.zoomGesture(phase: .began, factor: 1, at: centre))
        for _ in 0..<4 { #expect(controller.zoomGesture(phase: .changed, factor: 1.25, at: centre)) }
        #expect(controller.zoomGesture(phase: .ended, factor: 1, at: centre))
        undo.endUndoGrouping()
        #expect(counter.begins == 1 && counter.ends == 1)
        #expect(abs((placement(doc, page)?.zoom ?? 0) - pow(1.25, 4)) < 1e-9)
        undo.undo()
        #expect(placement(doc, page) == original)
        #expect(!undo.canUndo)

        // Outside the selected box, a pinch isn't a crop.
        #expect(!controller.zoomGesture(phase: .began, factor: 1, at: CGPoint(x: -50, y: -50)))
    }

    @Test func undoDuringCanvasDrag_stopsTheDrag() throws {
        let (doc, undo) = try makeDocument()
        let (page, _) = try placeVersion(doc, undo)
        let original = try #require(placement(doc, page))
        let (_, controller, counter) = canvas(doc, page: page, selected: imageBox.id)
        let rect = boxRect(doc)
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        perform(doc, undo, .setCrop(page: page, box: imageBox.id, zoom: 2, center: .center))
        undo.removeAllActions()
        let zoomed = try #require(placement(doc, page))

        undo.beginUndoGrouping()
        controller.mouseDown(with: mouseEvent(.leftMouseDown), at: centre)
        controller.mouseDragged(with: mouseEvent(.leftMouseDragged), at: CGPoint(x: centre.x + 10, y: centre.y))
        undo.endUndoGrouping()
        undo.undo()
        #expect(placement(doc, page) == zoomed)
        controller.mouseDragged(with: mouseEvent(.leftMouseDragged), at: CGPoint(x: centre.x + 30, y: centre.y))
        controller.mouseUp(with: mouseEvent(.leftMouseUp), at: CGPoint(x: centre.x + 30, y: centre.y))
        #expect(placement(doc, page) == zoomed, "nothing edits after the undo")
        #expect(counter.ends == 0)
        _ = original
    }

    // MARK: Drop target

    @Test func dropTarget_isTheImageBoxUnderThePointer() throws {
        let (doc, undo) = try makeDocument()
        let (page, _) = try placeVersion(doc, undo)
        let (view, controller, _) = canvas(doc, page: page, selected: nil)
        let rect = boxRect(doc)
        let transform = try #require(view.transform)
        let viewPoint = transform.toView(CGPoint(x: rect.midX, y: rect.midY))
        // Without a window, view and window coordinates differ only by the flip.
        let windowPoint = view.convert(viewPoint, to: nil)
        let target = view.dropTarget(atWindowLocation: windowPoint)
        #expect(target?.page == page && target?.box == imageBox.id)
        let text = story.textBoxes[0]
        let textRect = PageGeometry(setup: doc.content.style.pageSetup, kind: story.kind).renderRect(for: text)
        let textPoint = view.convert(transform.toView(CGPoint(x: textRect.midX, y: textRect.midY)), to: nil)
        #expect(view.dropTarget(atWindowLocation: textPoint) == nil, "text boxes aren't drop targets")
        _ = controller
    }
}
