import BBAICore
import BBModel
import Foundation
import Testing
@testable import BBAI

@Suite struct ReferenceSelectorTests {
    /// "@Pip yawning by the fire" sends Pip's one image and nothing else of Pip.
    @Test func mentionedAssetSendsItsOneImage() throws {
        var book = SliceBook.make()
        let pip = Cast.add(.character, "Pip", description: "A small red fox.", to: &book.content)
        let (request, report) = try assemble(book.target, assetIntent("\(mention(pip)) yawning by the fire"), content: book.content)
        #expect(sentLabels(report) == ["Pip"])
        #expect(report.referencesSent.allSatisfy { $0.role == "asset" })
        #expect(request.references.map(\.payload.ref) == [Cast.ref("Pip")])
        #expect(report.referencesOmitted.isEmpty)
    }

    @Test func tiersFillInOrder() throws {
        var walk = RefinementBook.make()
        var content = walk.book.content
        let pip = Cast.add(.character, "Pip", to: &content)
        let granny = Cast.add(.character, "Granny Oak", to: &content)
        let mill = Cast.add(.place, "Old Mill", to: &content)
        content.pages[walk.book.pageID]?.assetChecklist = [mill.id, granny.id, pip.id]
        content.style.styleReferences = (1...3).map { ImageRef(sha256: "style\($0)", contentType: "public.png") }
        walk.book.content = content
        let attached = VersionRef(sessionID: walk.book.sessionID, versionID: walk.versions[3].id)
        let intent = walk.refine(0, "\(mention(pip)) crying over her shoulder", attached: [attached])
        let (_, report) = try assemble(walk.book.target, intent, content: content, messageID: walk.pendingMessage)
        #expect(sentLabels(report) == [
            "Current illustration (v1)", "Reference v4",
            "Pip",                                   // tier 3: mentioned
            "Old Mill", "Granny Oak",                // tier 4: checklist order
            "Style reference 1", "Style reference 2", // tier 5
            "Style reference 3",                     // spare capacity
        ])
        #expect(report.referencesSent.map(\.role).prefix(3) == ["base", "reference", "asset"])
    }

    @Test func everyAssetTypeSendsOneImage() throws {
        var book = SliceBook.make()
        let pip = Cast.add(.character, "Pip", to: &book.content)
        let mill = Cast.add(.place, "Old Mill", to: &book.content)
        let key = Cast.add(.object, "Brass Key", to: &book.content)
        let message = "\(mention(pip)) happy and sad, from behind, at \(mention(mill)) at night with \(mention(key))"
        let (_, report) = try assemble(book.target, assetIntent(message), content: book.content)
        #expect(sentLabels(report) == ["Pip", "Old Mill", "Brass Key"])
    }

    @Test func styleReferencesCappedAtTwoUnlessSpare() throws {
        var book = SliceBook.make()
        let pip = Cast.add(.character, "Pip", to: &book.content)
        let granny = Cast.add(.character, "Granny Oak", to: &book.content)
        book.content.pages[book.pageID]?.assetChecklist = [granny.id]
        book.content.style.styleReferences = (1...4).map { ImageRef(sha256: "style\($0)", contentType: "public.png") }
        // Plenty of room: all four styles, the extra two last.
        let (_, roomy) = try assemble(book.target, assetIntent("\(mention(pip)) sleepy"), content: book.content)
        #expect(sentLabels(roomy) == ["Pip", "Granny Oak", "Style reference 1", "Style reference 2",
                                      "Style reference 3", "Style reference 4"])
        // Four images: the spare styles are what gets cut.
        var model = try testModel()
        model.image.maxReferenceImages = 4
        let (_, tight) = try assemble(book.target, assetIntent("\(mention(pip)) sleepy"), content: book.content, model: model)
        #expect(sentLabels(tight).count == 4)
        #expect(tight.referencesOmitted.map(\.label) == ["Style reference 3 (over the limit)", "Style reference 4 (over the limit)"])
    }

    @Test func imageLimitStopsAndListsTheRest() throws {
        var book = SliceBook.make()
        let pip = Cast.add(.character, "Pip", to: &book.content)
        let granny = Cast.add(.character, "Granny Oak", to: &book.content)
        let mill = Cast.add(.place, "Old Mill", to: &book.content)
        book.content.pages[book.pageID]?.assetChecklist = [mill.id]
        book.content.style.styleReferences = (1...3).map { ImageRef(sha256: "style\($0)", contentType: "public.png") }
        var model = try testModel()
        model.image.maxReferenceImages = 2
        let message = "\(mention(pip)) and \(mention(granny)), both yawning"
        let (_, report) = try assemble(book.target, assetIntent(message), content: book.content, model: model)
        #expect(sentLabels(report) == ["Pip", "Granny Oak"])
        #expect(ReferenceSelector.leftOutSummary(report.referencesOmitted)
            == "Left out: Old Mill; style reference 1; style reference 2; style reference 3.")
    }

    @Test func byteBudgetStopsAtTheFirstMisfit() throws {
        var book = SliceBook.make()
        let pip = Cast.add(.character, "Pip", to: &book.content)
        let granny = Cast.add(.character, "Granny Oak", to: &book.content)
        let key = Cast.add(.object, "Brass Key", to: &book.content)
        var data = Cast.imageData(book.content, size: 30)
        data[Cast.ref("Granny Oak")] = Data(count: 50)
        data[Cast.ref("Brass Key")] = Data(count: 5)
        var model = try testModel()
        model.image.maxRequestBytes = 70
        let message = "\(mention(pip)), \(mention(granny)) and \(mention(key))"
        let (_, report) = try assemble(book.target, assetIntent(message), content: book.content, model: model, imageData: data)
        // 30 + 50 > 70 stops selection; the small key after it is not squeezed in.
        #expect(sentLabels(report) == ["Pip"])
        #expect(report.referencesOmitted.map(\.label) == ["Granny Oak (over the limit)", "Brass Key (over the limit)"])
        #expect(report.estimatedInputBytes == report.promptText.utf8.count + 30)
    }

    @Test func leftOutWording() {
        let omitted = [
            SentReference(image: Cast.ref("Granny Oak"), role: "asset", label: "Granny Oak (over the limit)"),
            SentReference(image: ImageRef(sha256: "s3", contentType: "public.png"), role: "style", label: "Style reference 3 (file missing)"),
        ]
        #expect(ReferenceSelector.leftOutSummary(omitted) == "Left out: Granny Oak; style reference 3.")
        #expect(ReferenceSelector.leftOutSummary([]) == nil)
    }

    @Test func unchosenImageIsSkipped() throws {
        var book = SliceBook.make()
        let pip = Cast.add(.character, "Pip", options: .init(chosen: false), to: &book.content)
        let (request, report) = try assemble(book.target, assetIntent("\(mention(pip)) yawning"), content: book.content)
        #expect(sentLabels(report).isEmpty)
        #expect(report.referencesOmitted.isEmpty)
        // Still in the cast, without an image line.
        #expect(request.instruction.rendered.contains("- Pip (character)."))
    }

    @Test func chosenVersionThatIsGoneIsSkipped() throws {
        var book = SliceBook.make()
        let pip = Cast.add(.character, "Pip", to: &book.content)
        book.content.sessions[pip.sessionID]?.versions = []
        let (_, report) = try assemble(book.target, assetIntent("\(mention(pip)) yawning"), content: book.content)
        #expect(sentLabels(report).isEmpty)
        #expect(report.referencesOmitted.isEmpty)
    }

    @Test func duplicatesKeepTheHigherTier() throws {
        var book = SliceBook.make()
        let pip = Cast.add(.character, "Pip", to: &book.content)
        let attached = VersionRef(sessionID: pip.sessionID, versionID: try #require(pip.chosen))
        var value = assetIntent("\(mention(pip)) yawning")
        value.attachedReferences = [attached]
        let (_, report) = try assemble(book.target, value, content: book.content)
        #expect(sentLabels(report) == ["Reference v1"])
    }

    @Test func excludedAssetSendsNoImage() {
        var content = SliceBook.make().content
        let pip = Cast.add(.character, "Pip", to: &content)
        let granny = Cast.add(.character, "Granny Oak", to: &content)
        let candidates = ReferenceSelector.candidates(.init(
            assets: [.init(asset: pip, mentioned: true, excludesImage: true), .init(asset: granny, mentioned: false)],
            sessions: content.sessions))
        #expect(candidates.map(\.label) == ["Granny Oak"])
        #expect(candidates.map(\.tier) == [.checklistAsset])
    }

    @Test func selectSkipsMissingAndTooLargeButStopsAtBudget() {
        func c(_ name: String) -> ReferenceSelector.Candidate {
            .init(ref: ImageRef(sha256: name, contentType: "public.png"), role: "style", label: name, tier: .style)
        }
        let candidates = ["a", "missing", "huge", "b", "c", "d"].map(c)
        let sizes: [ImageRef: Int] = [candidates[0].ref: 10, candidates[2].ref: 500, candidates[3].ref: 10,
                                      candidates[4].ref: 10, candidates[5].ref: 1]
        let selection = ReferenceSelector.select(candidates, byteCounts: sizes,
                                                 limits: .init(maxImages: 2, maxImageBytes: 100, maxTotalBytes: 1000))
        #expect(selection.sent.map(\.label) == ["a", "b"])
        #expect(selection.omitted.map(\.reason) == [.fileMissing, .tooLarge, .overLimit, .overLimit])
        #expect(selection.bytes == 20)
    }
}
