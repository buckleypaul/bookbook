import BBAICore
import BBModel
import Foundation
import Testing
@testable import BBAI

@Suite struct RefinementContextTests {
    @Test func refiningV1AfterV4ShowsOnlyV1Lineage() throws {
        let walk = RefinementBook.make()
        // A fifth message branching from v1; v2 to v4 must stay out of its prompt.
        let (request, report) = try assembleBook(walk.book, walk.refine(0), messageID: walk.pendingMessage,
                                                 imageData: walk.imageData)
        assertPromptSnapshot(request.instruction.rendered)
        let text = request.instruction.rendered
        #expect(text.contains("1) A fox in the rain"))
        #expect(!text.contains("sky blue") && !text.contains("add a hat") && !text.contains("bigger umbrella"))
        #expect(report.promptText == text)
        #expect(request.baseImage?.ref == walk.versions[0].image)
    }

    @Test func refiningTheTipCondensesWholeChain() throws {
        let walk = RefinementBook.make()
        let (request, _) = try assembleBook(walk.book, walk.refine(3), messageID: walk.pendingMessage,
                                            imageData: walk.imageData)
        let text = request.instruction.rendered
        #expect(text.contains("1) A fox in the rain; 2) make the sky blue; 3) add a hat; 4) bigger umbrella"))
    }

    @Test func earlierEpochInstructionsAreExcluded() throws {
        var walk = RefinementBook.make()
        let id = walk.book.sessionID
        walk.book.content.sessions[id]?.resetEpoch = 1
        // Keep the pending message visible in the new epoch.
        if let index = walk.book.content.sessions[id]?.messages.firstIndex(where: { $0.id == walk.pendingMessage }) {
            walk.book.content.sessions[id]?.messages[index].epoch = 1
        }
        let (request, _) = try assembleBook(walk.book, walk.refine(1), messageID: walk.pendingMessage,
                                            imageData: walk.imageData)
        #expect(!request.instruction.sections.contains { $0.key == "history" })
    }

    @Test func refinementUsesBaseSizeAndPutsBaseFirst() throws {
        var walk = RefinementBook.make()
        let id = walk.book.sessionID
        walk.book.content.sessions[id]?.versions[1].pixelSize = PixelSize(width: 1536, height: 1024)
        let style = ImageRef(sha256: "style1", contentType: "public.png")
        walk.book.content.style.styleReferences = [style]
        var data = walk.imageData
        data[style] = Data("style".utf8)
        let (request, report) = try assembleBook(walk.book, walk.refine(1), messageID: walk.pendingMessage, imageData: data)
        #expect(request.output.exactSize == PixelSize(width: 1536, height: 1024))
        #expect(request.baseImage?.pixelSize == PixelSize(width: 1536, height: 1024))
        #expect(report.referencesSent.map(\.role) == ["base", "style"])
        #expect(request.references.map(\.sent.role) == ["style"])
        let text = request.instruction.rendered
        #expect(text.contains("Image 2 is a style reference"))
        #expect(text.contains("Image 1: the current illustration to edit"))
        #expect(text.contains("Image 2: style reference"))
    }

    @Test func newImageWithStyleReferences() throws {
        var book = SliceBook.make()
        let refs = (1...2).map { ImageRef(sha256: "s\($0)", contentType: "public.jpeg") }
        book.content.style.styleReferences = refs
        let data = Dictionary(uniqueKeysWithValues: refs.map { ($0, Data("x".utf8)) })
        let (request, report) = try assembleBook(book, imageData: data)
        #expect(request.baseImage == nil)
        #expect(request.output.exactSize == nil)
        #expect(request.references.map(\.payload.ref) == refs)
        #expect(request.references.first?.payload.contentType == "public.jpeg")
        #expect(report.referencesSent.map(\.role) == ["style", "style"])
        #expect(request.instruction.rendered.contains("Images 1–2 are style references"))
        #expect(!request.instruction.sections.contains { $0.key == "history" })
    }

    /// Phase 10: A §7.4 tiers put attached references (tier 2) before style references (tier 5).
    @Test func orderIsBaseThenAttachedThenStyle() throws {
        var walk = RefinementBook.make()
        let style = ImageRef(sha256: "style1", contentType: "public.png")
        walk.book.content.style.styleReferences = [style]
        let attached = VersionRef(sessionID: walk.book.sessionID, versionID: walk.versions[3].id)
        var data = walk.imageData
        data[style] = Data("s".utf8)
        let plan = try #require(ContextAssembler.plan(intent: walk.refine(0, attached: [attached]), target: walk.book.target,
                                                      messageID: walk.pendingMessage, content: walk.book.content))
        #expect(plan.map(\.role) == ["base", "reference", "style"])
        #expect(plan.map(\.ref) == [walk.versions[0].image, walk.versions[3].image, style])
        let (request, report) = try assembleBook(walk.book, walk.refine(0, attached: [attached]),
                                                 messageID: walk.pendingMessage, imageData: data)
        #expect(report.referencesSent.map(\.role) == ["base", "reference", "style"])
        #expect(request.references.map(\.sent.role) == ["reference", "style"])
        #expect(request.instruction.rendered.contains("Image 2: reference image"))
        #expect(request.instruction.rendered.contains("Image 3 is a style reference"))
    }

    @Test func attachedReferenceEqualToBaseIsNotRepeated() throws {
        let walk = RefinementBook.make()
        let attached = VersionRef(sessionID: walk.book.sessionID, versionID: walk.versions[0].id)
        let plan = try #require(ContextAssembler.plan(intent: walk.refine(0, attached: [attached]), target: walk.book.target,
                                                      messageID: walk.pendingMessage, content: walk.book.content))
        #expect(plan.map(\.role) == ["base"])
    }

    @Test func missingReferenceBytesAreOmitted() throws {
        var walk = RefinementBook.make()
        let style = ImageRef(sha256: "style1", contentType: "public.png")
        walk.book.content.style.styleReferences = [style]
        let (request, report) = try assembleBook(walk.book, walk.refine(0), messageID: walk.pendingMessage,
                                                 imageData: walk.imageData)
        #expect(report.referencesSent.map(\.role) == ["base"])
        #expect(report.referencesOmitted.map(\.image) == [style])
        #expect(report.referencesOmitted.first?.label.contains("file missing") == true)
        #expect(request.references.isEmpty)
        #expect(!request.instruction.rendered.contains("style reference"))
    }

    @Test func missingBaseBytesThrow() throws {
        let walk = RefinementBook.make()
        #expect(throws: AssemblyError.baseImageMissing) {
            try assembleBook(walk.book, walk.refine(0), messageID: walk.pendingMessage, imageData: [:])
        }
        #expect(AssemblyError.baseImageMissing.providerError == .invalidRequest(param: "image", nil))
    }

    @Test func refiningAVanishedVersionThrows() throws {
        let walk = RefinementBook.make()
        var gone = walk.refine(0)
        gone.refines = VersionID()
        #expect(throws: AssemblyError.baseVersionGone) {
            try assembleBook(walk.book, gone, messageID: walk.pendingMessage, imageData: walk.imageData)
        }
    }

    @Test func countCapIncludesTheBase() throws {
        var walk = RefinementBook.make()
        let styles = (1...3).map { ImageRef(sha256: "style\($0)", contentType: "public.png") }
        walk.book.content.style.styleReferences = styles
        var data = walk.imageData
        for ref in styles { data[ref] = Data("s".utf8) }
        var model = try testModel()
        model.image.maxReferenceImages = 3
        let (_, report) = try assembleBook(walk.book, walk.refine(0), messageID: walk.pendingMessage, model: model, imageData: data)
        #expect(report.referencesSent.count == 3)
        #expect(report.referencesSent.map(\.image) == [walk.versions[0].image, styles[0], styles[1]])
        #expect(report.referencesOmitted.map(\.image) == [styles[2]])
        #expect(report.referencesOmitted.first?.label.contains("over the limit") == true)
    }

    @Test func byteCapsOmitReferences() throws {
        var book = SliceBook.make()
        let refs = (1...3).map { ImageRef(sha256: "s\($0)", contentType: "public.png") }
        book.content.style.styleReferences = refs
        let data: [ImageRef: Data] = [refs[0]: Data(count: 40), refs[1]: Data(count: 200), refs[2]: Data(count: 40)]
        var model = try testModel()
        model.image.maxImageBytes = 100
        model.image.maxRequestBytes = 70
        let (_, report) = try assembleBook(book, model: model, imageData: data)
        // refs[1] is over the per-image cap; refs[2] would push the total past 70.
        #expect(report.referencesSent.map(\.image) == [refs[0]])
        #expect(report.referencesOmitted.map(\.image) == [refs[1], refs[2]])
    }

    @Test func attachedReferenceFromAnotherSession() throws {
        var walk = RefinementBook.make()
        let other = Version(image: ImageRef(sha256: "other", contentType: "public.png"),
                            pixelSize: PixelSize(width: 800, height: 800), source: .imported, createdAt: Date(timeIntervalSince1970: 0))
        let otherSession = Session(owner: .pageBox(PageID(), BoxID()), versions: [other])
        walk.book.content.sessions[otherSession.id] = otherSession
        let attached = VersionRef(sessionID: otherSession.id, versionID: other.id)
        var data = walk.imageData
        data[other.image] = Data("o".utf8)
        let (request, report) = try assembleBook(walk.book, walk.refine(0, attached: [attached]),
                                                 messageID: walk.pendingMessage, imageData: data)
        #expect(report.referencesSent.map(\.role) == ["base", "reference"])
        #expect(request.references.first?.payload.pixelSize == PixelSize(width: 800, height: 800))
    }

    @Test func messageSessionWithNoSlotDoesNotBorrowAnotherSessionsBox() throws {
        var walk = RefinementBook.make()
        // No slot holds the message's session and the target box now belongs to another session:
        // the request must not use that box's shape (Phase 16b #52).
        let page = walk.book.pageID, box = walk.book.imageBox
        let realID = walk.book.sessionID
        let empty = Session(owner: .pageBox(page, box))
        walk.book.content.sessions[empty.id] = empty
        walk.book.content.pages[page]?.images[box]?.sessionID = empty.id
        var content = walk.book.content
        content.sessions[realID] = walk.book.content.sessions[realID]
        #expect(throws: (any Error).self) {
            try assembleBook(walk.book, walk.refine(0), content: content, messageID: walk.pendingMessage,
                             imageData: walk.imageData)
        }
    }

    @Test func headerPixelSizeIsRead() {
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!
        #expect(ImageHeader.pixelSize(of: png) == PixelSize(width: 1, height: 1))
        #expect(ImageHeader.pixelSize(of: Data("nope".utf8)) == nil)
    }
}
