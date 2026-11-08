import BBAICore
import BBModel
import Foundation
import Testing
@testable import BBAI

@Suite struct EditSizeAndResolveTests {
    // MARK: Edit size snapping

    @Test(arguments: [(1024, 1536), (2550, 3300), (4032, 3024), (3000, 3000), (100, 100), (5000, 500), (1023, 1537)])
    func snappedEditSizeIsLegal(width: Int, height: Int) throws {
        let model = try testModel()
        guard case let .free(minRatio, maxRatio, multiple, minPixels, maxPixels, experimental) = model.image.aspect else {
            Issue.record("expected free")
            return
        }
        let size = try #require(AspectFitter.snap(PixelSize(width: width, height: height), model: model, quality: .draft))
        let ceiling = min(maxPixels, experimental ?? maxPixels)
        let ratio = Double(size.width) / Double(size.height)
        #expect(size.width % multiple == 0 && size.height % multiple == 0)
        #expect(size.width * size.height >= minPixels && size.width * size.height <= ceiling)
        #expect(ratio >= minRatio && ratio <= maxRatio)
        // Aspect stays close to the source's unless the source was outside the model's ratio limits.
        let source = min(max(Double(width) / Double(height), minRatio), maxRatio)
        #expect(abs(log(ratio / source)) < 0.1)
    }

    @Test func validSizeIsKept() throws {
        let size = PixelSize(width: 1024, height: 1536)
        #expect(AspectFitter.snap(size, model: try testModel(), quality: .draft) == size)
    }

    @Test func importedScanRefinementSendsSnappedSize() throws {
        var walk = RefinementBook.make()
        let id = walk.book.sessionID
        walk.book.content.sessions[id]?.versions[1].pixelSize = PixelSize(width: 2550, height: 3300)
        let (request, _) = try assembleBook(walk.book, walk.refine(1), messageID: walk.pendingMessage,
                                            imageData: walk.imageData)
        let size = try #require(request.output.exactSize)
        #expect(size != PixelSize(width: 2550, height: 3300))
        #expect(size.width % 16 == 0 && size.height % 16 == 0 && size.width * size.height <= 3_686_400)
    }

    // MARK: Resolution by message when the slot's box ID changed

    /// Moves the image slot to a brand-new box ID (the template's box was replaced).
    private func movedSlot(newAspectForOldID: Bool) -> (RefinementBook, BookContent, BoxID) {
        let walk = RefinementBook.make()
        var content = walk.book.content
        let pageID = walk.book.pageID, oldID = walk.book.imageBox
        let newBox = Box(frame: NormalizedRect(x: 0, y: 0, width: 1, height: 0.5), content: .image)
        var template = content.template(for: content.pages[pageID]!)!
        if newAspectForOldID {
            // The old ID now names a different (narrow, tall) image box with no session.
            let reused = Box(id: oldID, frame: NormalizedRect(x: 0, y: 0, width: 0.2, height: 1), content: .image)
            template.boxes = template.boxes.filter { $0.id != oldID } + [reused, newBox]
        } else {
            template.boxes = template.boxes.filter { $0.id != oldID } + [newBox]
        }
        content.templates[template.id] = template
        let slot = content.pages[pageID]!.images.removeValue(forKey: oldID)!
        content.pages[pageID]!.images[newBox.id] = slot
        return (walk, content, newBox.id)
    }

    @Test func sessionIsResolvedWhenSlotMovesToNewBoxID() throws {
        let (walk, content, newBox) = movedSlot(newAspectForOldID: false)
        let target = walk.book.target  // still names the old box ID
        let resolved = try #require(ContextAssembler.resolve(target: target, messageID: walk.pendingMessage, content: content))
        #expect(resolved.box.id == newBox)
        #expect(resolved.session.id == walk.book.sessionID)
        let (request, _) = try ContextAssembler.assemble(intent: walk.refine(0), target: target, messageID: walk.pendingMessage,
                                                         content: content, model: testModel(), imageData: walk.imageData)
        #expect(request.instruction.rendered.contains("A fox in the rain"))
        #expect(ContextAssembler.plan(intent: walk.refine(0), target: target, messageID: walk.pendingMessage, content: content) != nil)
    }

    @Test func oldBoxIDReusedByAnotherBoxUsesTheSessionsGeometry() throws {
        let (walk, content, newBox) = movedSlot(newAspectForOldID: true)
        let resolved = try #require(ContextAssembler.resolve(target: walk.book.target, messageID: walk.pendingMessage,
                                                             content: content))
        #expect(resolved.box.id == newBox)
        #expect(resolved.box.frame.width == 1)
    }

    @Test func withoutMessageTheTargetSlotIsUsed() {
        let (walk, content, _) = movedSlot(newAspectForOldID: false)
        #expect(ContextAssembler.resolve(target: walk.book.target, messageID: nil, content: content) == nil)
    }
}
