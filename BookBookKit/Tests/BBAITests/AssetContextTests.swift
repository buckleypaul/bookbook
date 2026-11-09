import BBAICore
import BBModel
import Foundation
import Testing
@testable import BBAI

/// Assets in play, the cast section, asset-session targets and the real-person check (Phase 10).
@Suite struct AssetContextTests {
    // MARK: Assets in play

    @Test func checklistAndCurrentMention() throws {
        var book = SliceBook.make()
        let pip = Cast.add(.character, "Pip", revision: 4, to: &book.content)
        let granny = Cast.add(.character, "Granny Oak", revision: 2, to: &book.content)
        let mill = Cast.add(.place, "Old Mill", to: &book.content)
        book.content.pages[book.pageID]?.assetChecklist = [granny.id, AssetID(), pip.id]
        let value = assetIntent("\(mention(mill)) at dusk with \(mention(pip))")
        #expect(ContextAssembler.assetsInPlay(intent: value, target: book.target, content: book.content)
            == [mill.id, pip.id, granny.id])
        let (_, report) = try assemble(book.target, value, content: book.content)
        #expect(report.assetRevisions == [pip.id: 4, granny.id: 2, mill.id: 1])
    }

    @Test func unknownMentionsAndChecklistEntriesAreIgnored() throws {
        var book = SliceBook.make()
        let ghost = AssetID()
        book.content.pages[book.pageID]?.assetChecklist = [ghost]
        let value = assetIntent("\(MentionText.token(for: ghost)) waves")
        #expect(ContextAssembler.assetsInPlay(intent: value, target: book.target, content: book.content).isEmpty)
        let (request, report) = try assemble(book.target, value, content: book.content)
        #expect(report.assetRevisions.isEmpty)
        #expect(!request.instruction.sections.contains { $0.key == "cast" })
        #expect(!request.instruction.rendered.contains("⟦"))
    }

    @Test func lineageMentionsCountButOtherBranchesDoNot() throws {
        var walk = RefinementBook.make()
        let pip = Cast.add(.character, "Pip", to: &walk.book.content)
        let granny = Cast.add(.character, "Granny Oak", to: &walk.book.content)
        let id = walk.book.sessionID
        // v1's message mentions Pip; v3's (not on v2's lineage) mentions Granny.
        let messages = try #require(walk.book.content.sessions[id]?.messages)
        let v1 = try #require(messages.firstIndex { $0.producedVersion == walk.versions[0].id })
        let v3 = try #require(messages.firstIndex { $0.producedVersion == walk.versions[2].id })
        walk.book.content.sessions[id]?.messages[v1].text = "\(mention(pip)) in the rain"
        walk.book.content.sessions[id]?.messages[v3].text = "add \(mention(granny))"
        let value = walk.refine(1, "make it night")
        #expect(ContextAssembler.assetsInPlay(intent: value, target: walk.book.target, messageID: walk.pendingMessage,
                                              content: walk.book.content) == [pip.id])
        let (request, _) = try assemble(walk.book.target, value, content: walk.book.content, messageID: walk.pendingMessage)
        // Mention tokens are names in the history, too.
        #expect(request.instruction.rendered.contains("1) Pip in the rain; 2) make the sky blue"))
        #expect(!request.instruction.rendered.contains("⟦"))
    }

    @Test func earlierEpochMentionsAreExcluded() throws {
        var walk = RefinementBook.make()
        let pip = Cast.add(.character, "Pip", to: &walk.book.content)
        let id = walk.book.sessionID
        let messages = try #require(walk.book.content.sessions[id]?.messages)
        let v1 = try #require(messages.firstIndex { $0.producedVersion == walk.versions[0].id })
        walk.book.content.sessions[id]?.messages[v1].text = "\(mention(pip)) in the rain"
        walk.book.content.sessions[id]?.resetEpoch = 1
        let value = walk.refine(1, "make it night")
        #expect(ContextAssembler.assetsInPlay(intent: value, target: walk.book.target, messageID: walk.pendingMessage,
                                              content: walk.book.content).isEmpty)
    }

    @Test func newImageIgnoresEarlierMessages() throws {
        var walk = RefinementBook.make()
        let pip = Cast.add(.character, "Pip", to: &walk.book.content)
        let id = walk.book.sessionID
        walk.book.content.sessions[id]?.messages[0].text = "\(mention(pip)) in the rain"
        #expect(ContextAssembler.assetsInPlay(intent: assetIntent("a new start"), target: walk.book.target,
                                              content: walk.book.content).isEmpty)
    }

    // MARK: Prompt

    @Test func promptWithCast() throws {
        var book = SliceBook.make(text: "Pip curled up by the fire. Granny Oak hummed.")
        let pip = Cast.add(.character, "Pip", description: "A small red fox with a white-tipped tail and a green scarf.",
                           to: &book.content)
        let granny = Cast.add(.character, "Granny Oak", description: "A kind old oak tree with a mossy shawl",
                              to: &book.content)
        let cottage = Cast.add(.place, "The Cottage", description: "A crooked stone cottage with a red door.",
                               options: .init(extraSlots: ["Inside"]), to: &book.content)
        book.content.pages[book.pageID]?.assetChecklist = [cottage.id, granny.id]
        book.content.style.styleReferences = [ImageRef(sha256: "style1", contentType: "public.png")]
        let (request, report) = try assemble(book.target, intent("\(mention(pip)) yawning by the fire inside the cottage"),
                                             content: book.content)
        assertPromptSnapshot(request.instruction.rendered)
        #expect(request.instruction.sections.map(\.key)
            == ["role", "style", "avoid", "cast", "composition", "story", "request", "legend"])
        let text = request.instruction.rendered
        #expect(text.contains("Pip yawning by the fire inside the cottage"))
        #expect(text.contains("Image 1 shows Pip (primary reference)."))
        #expect(text.contains("Image 1: Pip (primary reference). Keep Pip consistent with this image."))
        #expect(report.referencesSent.count == 9)
    }

    // MARK: Asset sessions

    @Test func sheetItemSendsThePrimaryAndAsksForTheItem() throws {
        var content = SliceBook.make().content
        content.style.styleReferences = [ImageRef(sha256: "style1", contentType: "public.png")]
        let pip = Cast.add(.character, "Pip", description: "A small red fox.", options: .init(chosenSheet: []), to: &content)
        let item = try #require(Cast.sheetItem(pip, .expression("sleepy")))
        let target = GenerationTarget.sheetItem(pip.id, item.id)
        let (request, report) = try assemble(target, assetIntent(SheetRequests.messageText(for: item.kind)), content: content)
        assertPromptSnapshot(request.instruction.rendered)
        #expect(sentLabels(report) == ["Pip – primary reference", "Style reference 1"])
        #expect(request.baseImage == nil)
        #expect(request.references.first?.payload.ref == Cast.ref("Pip", "primary"))
        #expect(request.output.boxAspect == 1 && request.output.exactSize == nil)
        #expect(request.instruction.sections.map(\.key) == ["role", "style", "avoid", "cast", "subject", "request", "legend"])
        let text = request.instruction.rendered
        #expect(text.contains("sleepy expression"))
        #expect(text.contains("Image 1 is the primary reference of Pip"))
        #expect(!text.contains("Composition") && !text.contains("Story text") && !text.contains("fold"))
        #expect(!report.storyTextIncluded)
        #expect(report.assetRevisions == [pip.id: 1])
    }

    @Test func sheetItemIgnoresOtherSheetItemsEvenWhenWordsMatch() throws {
        var content = SliceBook.make().content
        let pip = Cast.add(.character, "Pip", to: &content)
        let item = try #require(Cast.sheetItem(pip, .view(.back)))
        let (_, report) = try assemble(.sheetItem(pip.id, item.id), assetIntent("Back view, yawning"), content: content)
        #expect(sentLabels(report) == ["Pip – primary reference"])
        let view = try #require(Cast.sheetItem(pip, .view(.side)))
        let (request, _) = try assemble(.sheetItem(pip.id, view.id), assetIntent("Side view"), content: content)
        #expect(request.instruction.rendered.contains("side view (profile)"))
    }

    @Test func sheetItemRefinementPutsBaseFirst() throws {
        var content = SliceBook.make().content
        var pip = Cast.add(.character, "Pip", to: &content)
        let item = try #require(Cast.sheetItem(pip, .expression("happy")))
        let session = try #require(content.sessions[item.sessionID])
        let message = Message(role: .user, text: "make the smile bigger", queueItemID: QueueItemID(), createdAt: Date(timeIntervalSince1970: 1))
        content.sessions[item.sessionID]?.messages.append(message)
        var value = assetIntent("make the smile bigger")
        value.refines = try #require(session.versions.first?.id)
        // The message resolves the session even if the target's item ID is stale.
        pip = try #require(content.assets[pip.id])
        let (request, report) = try assemble(.sheetItem(pip.id, UUID()), value, content: content, messageID: message.id)
        #expect(report.referencesSent.map(\.role) == ["base", "asset"])
        #expect(request.baseImage?.ref == Cast.ref("Pip", "expr-happy"))
        #expect(request.output.exactSize != nil)
    }

    @Test func primaryReferenceSessionSendsNoOwnReference() throws {
        var content = SliceBook.make().content
        let pip = Cast.add(.character, "Pip", description: "A small red fox.", to: &content)
        let primary = try #require(pip.primary)
        let (request, report) = try assemble(.assetReference(pip.id, primary.id),
                                             assetIntent(SheetRequests.referenceMessageText(for: pip)), content: content)
        assertPromptSnapshot(request.instruction.rendered)
        #expect(report.referencesSent.isEmpty)
        #expect(request.output.boxAspect == 1)
        let text = request.instruction.rendered
        #expect(text.contains("full figure"))
        #expect(text.contains("- Pip (character): A small red fox."))
        #expect(!text.contains("Composition"))
    }

    @Test func otherSlotSessionSendsThePrimary() throws {
        var content = SliceBook.make().content
        let mill = Cast.add(.place, "Old Mill", options: .init(extraSlots: ["Night", "Day"]), to: &content)
        let night = try #require(mill.references.first { $0.label == "Night" })
        let (request, report) = try assemble(.assetReference(mill.id, night.id), assetIntent("At night, lanterns lit"),
                                             content: content)
        // Only the primary: the owner's other slots aren't sent.
        #expect(sentLabels(report) == ["Old Mill – primary reference"])
        #expect(request.instruction.rendered.contains("Draw another reference image of Old Mill: Night."))
        #expect(request.instruction.rendered.contains("Image 1 is the primary reference of Old Mill"))
    }

    @Test func assetSessionMentionsAddAssets() throws {
        var content = SliceBook.make().content
        let pip = Cast.add(.character, "Pip", to: &content)
        let granny = Cast.add(.character, "Granny Oak", to: &content)
        let slot = ReferenceSlot(label: "With Granny", isPrimary: false)
        content.assets[pip.id]?.references.append(slot)
        content.sessions[slot.sessionID] = Session(id: slot.sessionID, owner: .assetReference(pip.id, slot.id))
        let target = GenerationTarget.assetReference(pip.id, slot.id)
        let value = assetIntent("\(mention(granny)) and \(mention(pip)) yawning")
        #expect(ContextAssembler.assetsInPlay(intent: value, target: target, content: content) == [pip.id, granny.id])
        let (_, report) = try assemble(target, value, content: content)
        #expect(sentLabels(report) == ["Pip – primary reference", "Granny Oak – primary reference",
                                       "Granny Oak – sleepy expression", "Granny Oak – three-quarter view"])
    }

    @Test func goneAssetTargetsThrow() throws {
        var content = SliceBook.make().content
        let pip = Cast.add(.character, "Pip", to: &content)
        let model = try testModel()
        func ok(_ target: GenerationTarget) -> Bool {
            (try? ContextAssembler.assemble(intent: assetIntent("x"), target: target, content: content, model: model)) != nil
        }
        #expect(ok(.assetReference(pip.id, try #require(pip.primary).id)))
        #expect(!ok(.assetReference(AssetID(), try #require(pip.primary).id)))
        #expect(!ok(.assetReference(pip.id, UUID())))
        #expect(!ok(.sheetItem(pip.id, UUID())))
        #expect(ContextAssembler.plan(intent: assetIntent("x"), target: .sheetItem(AssetID(), UUID()), content: content) == nil)
    }

    @Test func sheetMessageText() {
        #expect(SheetRequests.messageText(for: .view(.threeQuarter)) == "Three-quarter view")
        #expect(SheetRequests.messageText(for: .expression("Sleepy")) == "Sleepy expression")
        #expect(SheetRequests.messageText(for: .expression("very cross")) == "Very cross expression")
    }

    @Test func costEstimateWorksForSheetItems() throws {
        var content = SliceBook.make().content
        let pip = Cast.add(.character, "Pip", to: &content)
        let item = try #require(Cast.sheetItem(pip, .view(.back)))
        let input = try #require(CostEstimator.estimateInput(intent: assetIntent("Back view"), target: .sheetItem(pip.id, item.id),
                                                             content: content, catalog: try ModelCatalog.bundled()))
        #expect(input.inputImageSizes == [PixelSize(width: 1024, height: 1024)])
        #expect(input.outputSize.width == input.outputSize.height)
    }

    // MARK: Queue

    @Test func queueFillsAssetRevisionsAndRunsSheetItems() async throws {
        var book = SliceBook.make()
        let pip = Cast.add(.character, "Pip", revision: 7, to: &book.content)
        let item = try #require(Cast.sheetItem(pip, .expression("sleepy")))
        let provider = FakeProvider(outcomes: [.success(okResult()), .success(okResult())], gated: false)
        let host = FakeHost(content: book.content, images: Cast.imageData(book.content))
        let queue = GenerationQueue(providers: [.openai: provider], catalog: try ModelCatalog.bundled(), host: host,
                                    pricing: FakePricing(), now: { Date(timeIntervalSince1970: 100) })
        let pageItem = QueueItem(bookID: book.content.book.id, target: book.target, messageID: MessageID(),
                                 intent: assetIntent("\(mention(pip)) yawning"))
        let sheetItem = QueueItem(bookID: book.content.book.id, target: .sheetItem(pip.id, item.id), messageID: MessageID(),
                                  intent: assetIntent("Sleepy expression"))
        await queue.enqueue([pageItem, sheetItem])
        await eventually("deliveries") { await host.delivered().count == 2 }
        let deliveries = await host.delivered()
        for delivery in deliveries {
            guard case let .success(_, provenance) = delivery.outcome else {
                Issue.record("expected success")
                continue
            }
            #expect(provenance.assetRevisions == [pip.id: 7])
            #expect(provenance.referencesSent.first?.label == "Pip – primary reference")
        }
        #expect(deliveries.map(\.item.target) == [book.target, .sheetItem(pip.id, item.id)])
        // The persisted form round-trips the new target case.
        let data = try JSONEncoder().encode(sheetItem)
        #expect(try JSONDecoder().decode(QueueItem.self, from: data) == sheetItem)
    }

    // MARK: Real-person photos (A §11)

    @Test func realPersonPhotoIsDetectedAfterSelection() throws {
        var walk = RefinementBook.make()
        let pip = Cast.add(.character, "Pip", options: .init(primaryIsRealPerson: true), to: &walk.book.content)
        let content = walk.book.content
        var model = try testModel()
        func sends(_ intent: GenerationIntent, _ target: GenerationTarget? = nil) -> Bool {
            ContextAssembler.sendsRealPersonPhoto(intent: intent, target: target ?? walk.book.target, content: content, model: model)
        }
        #expect(sends(assetIntent("\(mention(pip)) waves")))
        #expect(!sends(assetIntent("a fox waves")))
        // A sheet item of Pip sends Pip's primary.
        let item = try #require(Cast.sheetItem(pip, .view(.side)))
        #expect(sends(assetIntent("Side view"), .sheetItem(pip.id, item.id)))
        // The base fills the only image slot, so Pip's photo is cut and not sent.
        model.image.maxReferenceImages = 1
        #expect(!sends(walk.refine(0, "\(mention(pip)) waves")))
    }

    @Test func realPersonBaseImageCounts() throws {
        var walk = RefinementBook.make()
        let id = walk.book.sessionID
        walk.book.content.sessions[id]?.versions[0].depictsRealPerson = true
        #expect(ContextAssembler.sendsRealPersonPhoto(intent: walk.refine(0), target: walk.book.target,
                                                      content: walk.book.content, model: try testModel()))
        #expect(!ContextAssembler.sendsRealPersonPhoto(intent: walk.refine(1), target: walk.book.target,
                                                       content: walk.book.content, model: try testModel()))
    }
}
