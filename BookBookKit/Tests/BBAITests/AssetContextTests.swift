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
                               to: &book.content)
        book.content.pages[book.pageID]?.assetChecklist = [cottage.id, granny.id]
        book.content.style.styleReferences = [ImageRef(sha256: "style1", contentType: "public.png")]
        let (request, report) = try assemble(book.target, intent("\(mention(pip)) yawning by the fire inside the cottage"),
                                             content: book.content)
        assertPromptSnapshot(request.instruction.rendered)
        #expect(request.instruction.sections.map(\.key)
            == ["role", "style", "avoid", "cast", "composition", "story", "request", "legend"])
        let text = request.instruction.rendered
        #expect(text.contains("Pip yawning by the fire inside the cottage"))
        #expect(text.contains("Image 1 shows Pip."))
        #expect(text.contains("Image 1: Pip. Keep Pip consistent with this image."))
        // One image per asset, then the style reference.
        #expect(sentLabels(report) == ["Pip", "The Cottage", "Granny Oak", "Style reference 1"])
    }

    // MARK: Asset sessions

    @Test func assetSessionSendsNoOwnImage() throws {
        var content = SliceBook.make().content
        let pip = Cast.add(.character, "Pip", description: "A small red fox.", to: &content)
        // The asset editor sends the description as the request (PD §8.3).
        let (request, report) = try assemble(.asset(pip.id), assetIntent(pip.description), content: content)
        assertPromptSnapshot(request.instruction.rendered)
        #expect(report.referencesSent.isEmpty)
        #expect(request.baseImage == nil)
        #expect(request.output.boxAspect == 1 && request.output.exactSize == nil)
        #expect(request.instruction.sections.map(\.key) == ["role", "style", "avoid", "cast", "subject", "request"])
        let text = request.instruction.rendered
        #expect(text.contains("full figure"))
        // The cast names the owner without repeating the description the request carries.
        #expect(text.contains("- Pip (character)."))
        #expect(text.components(separatedBy: "A small red fox.").count == 2, "the description appears once")
        #expect(!text.contains("Composition") && !text.contains("Story text") && !text.contains("fold"))
        #expect(!report.storyTextIncluded)
        #expect(report.assetRevisions == [pip.id: 1])
    }

    @Test(arguments: [(AssetType.character, "full figure"), (.place, "the whole place"), (.object, "the whole object")])
    func assetSessionSubjectFollowsType(type: AssetType, wording: String) throws {
        var content = SliceBook.make().content
        let asset = Cast.add(type, "Thing", to: &content)
        let (request, _) = try assemble(.asset(asset.id), assetIntent("Make it"), content: content)
        #expect(request.instruction.rendered.contains("Draw a reference image of Thing"))
        #expect(request.instruction.rendered.contains(wording))
    }

    @Test func assetSessionRefinementPutsBaseFirst() throws {
        var content = SliceBook.make().content
        let pip = Cast.add(.character, "Pip", to: &content)
        let session = try #require(content.sessions[pip.sessionID])
        let message = Message(role: .user, text: "make the smile bigger", queueItemID: QueueItemID(), createdAt: Date(timeIntervalSince1970: 1))
        content.sessions[pip.sessionID]?.messages.append(message)
        var value = assetIntent("make the smile bigger")
        value.refines = try #require(session.versions.first?.id)
        // The message resolves the session even if the target's asset ID is stale.
        let (request, report) = try assemble(.asset(AssetID()), value, content: content, messageID: message.id)
        #expect(report.referencesSent.map(\.role) == ["base"])
        #expect(request.baseImage?.ref == Cast.ref("Pip"))
        #expect(request.output.exactSize != nil)
    }

    @Test func assetSessionMentionsAddAssets() throws {
        var content = SliceBook.make().content
        let pip = Cast.add(.character, "Pip", to: &content)
        let granny = Cast.add(.character, "Granny Oak", to: &content)
        let target = GenerationTarget.asset(pip.id)
        let value = assetIntent("\(mention(granny)) and \(mention(pip)) yawning")
        #expect(ContextAssembler.assetsInPlay(intent: value, target: target, content: content) == [pip.id, granny.id])
        let (_, report) = try assemble(target, value, content: content)
        // Mentioning the owner in its own session still doesn't send its own image.
        #expect(sentLabels(report) == ["Granny Oak"])
    }

    @Test func goneAssetTargetsThrow() throws {
        var content = SliceBook.make().content
        let pip = Cast.add(.character, "Pip", to: &content)
        let model = try testModel()
        func ok(_ target: GenerationTarget) -> Bool {
            (try? ContextAssembler.assemble(intent: assetIntent("x"), target: target, content: content, model: model)) != nil
        }
        #expect(ok(.asset(pip.id)))
        #expect(!ok(.asset(AssetID())))
        // The asset's session is gone.
        content.sessions[pip.sessionID] = nil
        #expect(!ok(.asset(pip.id)))
        #expect(ContextAssembler.plan(intent: assetIntent("x"), target: .asset(AssetID()), content: content) == nil)
    }

    @Test func costEstimateWorksForAssetSessions() throws {
        var content = SliceBook.make().content
        let pip = Cast.add(.character, "Pip", to: &content)
        let input = try #require(CostEstimator.estimateInput(intent: assetIntent("Reference image of Pip"), target: .asset(pip.id),
                                                             content: content, catalog: try ModelCatalog.bundled()))
        #expect(input.inputImageSizes.isEmpty)
        #expect(input.outputSize.width == input.outputSize.height)
    }

    // MARK: Queue

    @Test func queueFillsAssetRevisionsAndRunsAssetSessions() async throws {
        var book = SliceBook.make()
        let pip = Cast.add(.character, "Pip", revision: 7, to: &book.content)
        let provider = FakeProvider(outcomes: [.success(okResult()), .success(okResult())], gated: false)
        let host = FakeHost(content: book.content, images: Cast.imageData(book.content))
        let queue = GenerationQueue(providers: [.openai: provider], catalog: try ModelCatalog.bundled(), host: host,
                                    pricing: FakePricing(), now: { Date(timeIntervalSince1970: 100) })
        let pageItem = QueueItem(bookID: book.content.book.id, target: book.target, messageID: MessageID(),
                                 intent: assetIntent("\(mention(pip)) yawning"))
        let assetItem = QueueItem(bookID: book.content.book.id, target: .asset(pip.id), messageID: MessageID(),
                                  intent: assetIntent("Reference image of Pip"))
        await queue.enqueue([pageItem, assetItem])
        await eventually("deliveries") { await host.delivered().count == 2 }
        let deliveries = await host.delivered()
        #expect(deliveries.map(\.item.target) == [book.target, .asset(pip.id)])
        for delivery in deliveries {
            guard case let .success(_, provenance) = delivery.outcome else {
                Issue.record("expected success")
                continue
            }
            #expect(provenance.assetRevisions == [pip.id: 7])
            // The page sends Pip's image; Pip's own session doesn't.
            #expect(provenance.referencesSent.map(\.label) == (delivery.item.target == book.target ? ["Pip"] : []))
        }
        // The persisted form round-trips the asset target case.
        let data = try JSONEncoder().encode(assetItem)
        #expect(try JSONDecoder().decode(QueueItem.self, from: data) == assetItem)
    }

    // MARK: Real-person photos (A §11)

    @Test func realPersonPhotoIsDetectedAfterSelection() throws {
        var walk = RefinementBook.make()
        let pip = Cast.add(.character, "Pip", options: .init(isRealPerson: true), to: &walk.book.content)
        let content = walk.book.content
        var model = try testModel()
        func sends(_ intent: GenerationIntent, _ target: GenerationTarget? = nil) -> Bool {
            ContextAssembler.sendsRealPersonPhoto(intent: intent, target: target ?? walk.book.target, content: content, model: model)
        }
        #expect(sends(assetIntent("\(mention(pip)) waves")))
        #expect(!sends(assetIntent("a fox waves")))
        // Pip's own session doesn't send Pip's image.
        #expect(!sends(assetIntent("Reference image of Pip"), .asset(pip.id)))
        // The base fills the only image slot, so Pip's photo is cut and not sent.
        model.image.maxReferenceImages = 1
        #expect(!sends(walk.refine(0, "\(mention(pip)) waves")))
    }

    // MARK: Reference photo (PD §8.3)

    static func photo(_ name: String, real: Bool = true) -> AssetReferencePhoto {
        AssetReferencePhoto(image: Cast.ref(name, "photo"), pixelSize: PixelSize(width: 1536, height: 1024),
                            depictsRealPerson: real)
    }

    @Test func assetSessionSendsItsReferencePhotoFirst() throws {
        var content = SliceBook.make().content
        content.style.styleReferences = [Cast.ref("style", "1")]
        var pip = Cast.add(.character, "Pip", description: "A curious girl of six.", to: &content)
        pip.referencePhoto = Self.photo("Pip")
        content.assets[pip.id] = pip
        let (request, report) = try assemble(.asset(pip.id), assetIntent(pip.description), content: content)
        assertPromptSnapshot(request.instruction.rendered)
        #expect(report.referencesSent.map(\.role) == ["photo", "style"])
        #expect(report.referencesSent.first?.image == Cast.ref("Pip", "photo"))
        #expect(request.baseImage == nil, "a photo is a reference, never the image being edited")
        #expect(request.references.first?.payload.ref == Cast.ref("Pip", "photo"))
        let text = request.instruction.rendered
        #expect(text.contains("Image 1: a photo of Pip."))
        #expect(text.contains("- Pip (character). Image 1 shows Pip."))
        // The asset's current image still isn't sent for itself.
        #expect(!report.referencesSent.contains { $0.image == Cast.ref("Pip") })
    }

    @Test func pageRequestsNeverSendTheReferencePhoto() throws {
        var book = SliceBook.make()
        var pip = Cast.add(.character, "Pip", to: &book.content)
        pip.referencePhoto = Self.photo("Pip")
        book.content.assets[pip.id] = pip
        book.content.pages[book.pageID]?.assetChecklist = [pip.id]
        let (_, report) = try assemble(book.target, assetIntent("\(mention(pip)) waves"), content: book.content)
        #expect(sentLabels(report) == ["Pip"])
        #expect(!report.referencesSent.contains { $0.image == Cast.ref("Pip", "photo") })
        #expect(!ContextAssembler.sendsRealPersonPhoto(intent: assetIntent("\(mention(pip)) waves"),
                                                       target: book.target, content: book.content, model: try testModel()))
    }

    @Test func realPersonReferencePhotoNeedsTheNotice() throws {
        var content = SliceBook.make().content
        var pip = Cast.add(.character, "Pip", to: &content)
        var toy = Cast.add(.object, "Bear", to: &content)
        pip.referencePhoto = Self.photo("Pip")
        toy.referencePhoto = Self.photo("Bear", real: false)
        content.assets[pip.id] = pip
        content.assets[toy.id] = toy
        let model = try testModel()
        #expect(ContextAssembler.sendsRealPersonPhoto(intent: assetIntent("Pip"), target: .asset(pip.id),
                                                      content: content, model: model))
        #expect(!ContextAssembler.sendsRealPersonPhoto(intent: assetIntent("Bear"), target: .asset(toy.id),
                                                       content: content, model: model))
    }

    /// Review fix: the report records which images sent were real-person photos, and the
    /// advice context derives rule 1's fact from it (A §7.11).
    @Test func reportMarksRealPersonReferences_andAdviceUsesIt() throws {
        var content = SliceBook.make().content
        content.style.styleReferences = [Cast.ref("style", "1")]
        var pip = Cast.add(.character, "Pip", to: &content)
        var toy = Cast.add(.object, "Bear", to: &content)
        pip.referencePhoto = Self.photo("Pip")
        toy.referencePhoto = Self.photo("Bear", real: false)
        content.assets[pip.id] = pip
        content.assets[toy.id] = toy

        let (_, real) = try assemble(.asset(pip.id), assetIntent("Pip"), content: content)
        #expect(real.referencesSent.map(\.depictsRealPerson) == [true, false], "photo, then style")
        #expect(real.sentRealPersonPhoto)
        let (_, clean) = try assemble(.asset(toy.id), assetIntent("Bear"), content: content)
        #expect(!clean.sentRealPersonPhoto)

        // Omitted references keep the flag too (Version details), but only sent ones count.
        var data = Cast.imageData(content)
        data[Cast.ref("Pip", "photo")] = nil
        let (_, missing) = try assemble(.asset(pip.id), assetIntent("Pip"), content: content, imageData: data)
        #expect(missing.referencesOmitted.map(\.depictsRealPerson) == [true])
        #expect(!missing.sentRealPersonPhoto)

        let refused = ProviderError.refused(stage: .input, categories: [], nil)
        let advice = RefusalAdvisor.advise(refused, context: AdviceContext(provider: .openai, report: real))
        #expect(advice.fixes == ["Describe the child in words instead of uploading a photo."])
        #expect(RefusalAdvisor.advise(refused, context: AdviceContext(provider: .openai, report: clean)).fixes
            != advice.fixes)
        #expect(!AdviceContext(provider: .openai, report: nil).includesRealPersonPhoto)
        #expect(!AdviceContext(provider: .openai, report: real, includesRealPersonPhoto: false).includesRealPersonPhoto)
    }

    @Test func missingReferencePhotoBytesAreReportedNotFatal() throws {
        var content = SliceBook.make().content
        var pip = Cast.add(.character, "Pip", to: &content)
        pip.referencePhoto = Self.photo("Pip")
        content.assets[pip.id] = pip
        var data = Cast.imageData(content)
        data[Cast.ref("Pip", "photo")] = nil
        let (_, report) = try assemble(.asset(pip.id), assetIntent("Pip"), content: content, imageData: data)
        #expect(report.referencesSent.isEmpty)
        #expect(report.referencesOmitted.map(\.label) == ["Reference photo (file missing)"])
        #expect(ReferenceSelector.leftOutSummary(report.referencesOmitted) == "Left out: reference photo.")
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
