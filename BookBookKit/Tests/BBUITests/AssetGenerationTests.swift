import BBAI
import BBAICore
import BBModel
import BBStore
import Foundation
import Testing
@testable import BBUI

/// Phase 10: generation for asset targets, Generate whole sheet, the real-person notice check,
/// and the pure helpers behind @mentions, the reference picker and Version details.
@MainActor
struct AssetGenerationTests {
    private struct Setup {
        var h: Phase9Harness
        var app: AppModel
        var document: BookDocument
        var pip: Asset
    }

    private func setup() throws -> Setup {
        let h = try Phase9Harness()
        var content = Fixtures.book(pages: 1)
        let pip = Asset.makeNew(type: .character, name: "Pip")
        content.assets[pip.id] = pip
        for (id, owner) in pip.ownedSessions { content.sessions[id] = Session(id: id, owner: owner) }
        let url = h.dir.appending(path: "Sheet.bookbook", directoryHint: .isDirectory)
        try BookStore.create(content, at: url)
        let document = BookDocument(content: content, store: BookStore(packageURL: url))
        return Setup(h: h, app: h.makeApp(), document: document, pip: pip)
    }

    @Test func generate_forAssetTarget_appendsPendingMessageWithAttachments() throws {
        let s = try setup()
        defer { s.h.tearDown() }
        let primary = try #require(s.pip.primary)
        let ref = VersionRef(sessionID: SessionID(), versionID: VersionID())
        #expect(s.app.generate(prompt: "  Pip, front view  ", quality: .draft, includeStoryText: false, refines: nil,
                               attachedReferences: [ref], target: .assetReference(s.pip.id, primary.id),
                               in: s.document))
        let message = try #require(s.document.content.sessions[primary.sessionID]?.messages.first)
        #expect(message.text == "Pip, front view")
        #expect(message.attachedReferences == [ref])
        #expect(message.queueItemID != nil)
        #expect(s.app.isPending(message))
        // Empty prompts and missing targets queue nothing.
        #expect(!s.app.generate(prompt: " ", quality: .draft, includeStoryText: false, refines: nil,
                                attachedReferences: [], target: .assetReference(s.pip.id, primary.id), in: s.document))
        #expect(!s.app.generate(prompt: "x", quality: .draft, includeStoryText: false, refines: nil,
                                attachedReferences: [], target: .sheetItem(s.pip.id, UUID()), in: s.document))
    }

    @Test func pageGenerate_stillWritesToTheBoxSession() throws {
        let s = try setup()
        defer { s.h.tearDown() }
        let page = Fixtures.firstPage(s.document.content)
        #expect(s.app.generate(prompt: "a fox", quality: .draft, includeStoryText: true, refines: nil,
                               page: page, box: Fixtures.imageBox.id, in: s.document))
        let sessionID = try #require(s.document.content.pages[page]?.images[Fixtures.imageBox.id]?.sessionID)
        #expect(s.document.content.sessions[sessionID]?.messages.map(\.text) == ["a fox"])
    }

    @Test func sheetBatchPlan_skipsLockedAndPending_countsAndTotals() throws {
        let s = try setup()
        defer { s.h.tearDown() }
        var pip = s.pip
        let items = try #require(pip.sheet?.items)
        #expect(items.count == 8)
        // Lock the side view; queue something for the back view.
        pip.sheet?.items[1].locked = true
        s.document.perform(.updateAsset(pip, actionName: "Lock Sheet Item"))
        #expect(s.app.generate(prompt: "Back view", quality: .draft, includeStoryText: false, refines: nil,
                               attachedReferences: [], target: .sheetItem(pip.id, items[2].id), in: s.document))

        let plan = s.app.sheetBatchPlan(asset: pip.id, in: s.document)
        #expect(plan.count == 6)
        #expect(plan.sheetItems == items.enumerated().filter { $0.offset != 1 && $0.offset != 2 }.map(\.element.id))
        for (item, id) in zip(plan.items, plan.sheetItems) {
            let sheetItem = try #require(items.first { $0.id == id })
            #expect(item.target == .sheetItem(pip.id, id))
            #expect(item.intent.messageText == SheetRequests.messageText(for: sheetItem.kind))
            #expect(item.intent.quality == s.app.defaults.quality)
            #expect(item.intent.refines == nil)
            #expect(item.display.pageLabel == "Pip")
        }
        #expect(plan.estimate == CostEstimate.total(plan.items.map(\.estimate)))
        #expect(s.app.sheetBatchPlan(asset: AssetID(), in: s.document).count == 0)

        // Planning changed nothing; enqueueing appends one pending message per item.
        let before = s.document.content
        #expect(s.document.content == before)
        #expect(s.app.enqueueSheetBatch(plan, in: s.document))
        for (item, id) in zip(plan.items, plan.sheetItems) {
            let sessionID = try #require(items.first { $0.id == id }?.sessionID)
            let message = try #require(s.document.content.sessions[sessionID]?.messages.last)
            #expect(message.id == item.messageID)
            #expect(message.queueItemID == item.id)
        }
        // Everything is pending now: a second plan is empty, and the same plan isn't queued twice.
        #expect(s.app.sheetBatchPlan(asset: pip.id, in: s.document).count == 0)
        #expect(!s.app.enqueueSheetBatch(plan, in: s.document))
    }

    @Test func enqueueSheetBatch_skipsItemsLockedSincePlanning() throws {
        let s = try setup()
        defer { s.h.tearDown() }
        let plan = s.app.sheetBatchPlan(asset: s.pip.id, in: s.document)
        #expect(plan.count == 8)
        var pip = s.pip
        for i in pip.sheet!.items.indices { pip.sheet?.items[i].locked = true }
        s.document.perform(.updateAsset(pip, actionName: "Lock Sheet Item"))
        #expect(!s.app.enqueueSheetBatch(plan, in: s.document))
    }

    @Test func realPersonNotice_dependsOnAssemblerAndAcknowledgement() throws {
        let s = try setup()
        defer { s.h.tearDown() }
        let primary = try #require(s.pip.primary)
        // A real-person photo chosen as Pip's primary reference, Pip ticked on the page.
        let photo = Version(image: Fixtures.ref, pixelSize: PixelSize(width: 1024, height: 1024), source: .imported,
                            createdAt: Fixtures.date, depictsRealPerson: true)
        s.document.performIrreversible { content in
            BookMutations.appendImportedAssetVersion(image: Fixtures.ref, pixelSize: photo.pixelSize,
                                                     owner: .assetReference(s.pip.id, primary.id),
                                                     depictsRealPerson: true, to: &content, now: Fixtures.date)
        }
        let page = Fixtures.firstPage(s.document.content)
        s.document.perform(.setAssetChecklist(page: page, [s.pip.id]))
        let target = GenerationTarget.pageBox(page, Fixtures.imageBox.id)
        let intent = s.app.generationIntent(prompt: "Pip in the garden", quality: .draft, includeStoryText: true,
                                            refines: nil)
        let model = try #require(s.app.catalog.imageModel(provider: intent.provider, id: intent.model))
        let sends = ContextAssembler.sendsRealPersonPhoto(intent: intent, target: target, content: s.document.content,
                                                          model: model)
        #expect(s.app.realPersonNoticeNeeded(intent: intent, target: target, in: s.document) == (sends ? .openai : nil))

        s.app.acknowledgeRealPersonNotice(.openai, in: s.document)
        s.app.acknowledgeRealPersonNotice(.openai, in: s.document)
        #expect(s.document.content.book.acknowledgements.realPersonPhotoNotice == [.openai])
        #expect(s.app.realPersonNoticeNeeded(intent: intent, target: target, in: s.document) == nil)
    }

    /// Review fix: Generate Whole Sheet and Draft All run the same real-person check as a single send.
    @Test func batches_needTheRealPersonNotice_untilAcknowledged() throws {
        let s = try setup()
        defer { s.h.tearDown() }
        let primary = try #require(s.pip.primary)
        s.document.performIrreversible { content in
            BookMutations.appendImportedAssetVersion(image: Fixtures.ref, pixelSize: PixelSize(width: 1024, height: 1024),
                                                     owner: .assetReference(s.pip.id, primary.id),
                                                     depictsRealPerson: true, to: &content, now: Fixtures.date)
        }
        let page = Fixtures.firstPage(s.document.content)
        s.document.perform(.setAssetChecklist(page: page, [s.pip.id]))

        let sheet = s.app.sheetBatchPlan(asset: s.pip.id, in: s.document)
        #expect(sheet.count > 0)
        #expect(s.app.realPersonNoticeNeeded(for: sheet.items, in: s.document) == .openai)
        let draft = s.app.draftAllPlan(in: s.document)
        #expect(draft.count > 0)
        #expect(s.app.realPersonNoticeNeeded(for: draft.items, in: s.document) == .openai)

        s.app.acknowledgeRealPersonNotice(.openai, in: s.document)
        #expect(s.app.realPersonNoticeNeeded(for: sheet.items, in: s.document) == nil)
        #expect(s.app.realPersonNoticeNeeded(for: draft.items, in: s.document) == nil)
        #expect(s.app.realPersonNoticeNeeded(for: [], in: s.document) == nil)
    }

    @Test func batchNotice_oneNeedingItemAmongCleanOnes_andMixedProviders() throws {
        let s = try setup()
        defer { s.h.tearDown() }
        let primary = try #require(s.pip.primary)
        s.document.performIrreversible { content in
            BookMutations.appendImportedAssetVersion(image: Fixtures.ref, pixelSize: PixelSize(width: 1024, height: 1024),
                                                     owner: .assetReference(s.pip.id, primary.id),
                                                     depictsRealPerson: true, to: &content, now: Fixtures.date)
        }
        // Pip is ticked on the story page only; the cover's request is clean.
        let page = Fixtures.firstPage(s.document.content)
        s.document.perform(.setAssetChecklist(page: page, [s.pip.id]))
        let items = s.app.draftAllPlan(in: s.document).items
        #expect(items.count == 2)
        let needing = try #require(items.first { $0.target == .pageBox(page, Fixtures.imageBox.id) })
        let clean = try #require(items.first { $0.id != needing.id })
        #expect(s.app.realPersonNoticeNeeded(for: [clean], in: s.document) == nil)
        #expect(s.app.realPersonNoticeNeeded(for: [clean, needing, clean], in: s.document) == .openai)

        // A second provider (no catalog model, so never a notice) does not hide the first.
        var other = clean
        other.intent.provider = .gemini
        #expect(s.app.realPersonNoticeNeeded(for: [other, needing], in: s.document) == .openai)
        s.app.acknowledgeRealPersonNotice(.openai, in: s.document)
        #expect(s.app.realPersonNoticeNeeded(for: [other, needing], in: s.document) == nil)
    }

    @Test func flagText_hasAnAssetChangedEntry() {
        let entries = FlagText.entries([.assetChanged])
        #expect(entries.map(\.title) == ["Asset changed"])
        #expect(!entries[0].help.isEmpty)
        #expect(FlagText.entries([.styleChanged, .assetChanged, .layoutChanged]).count == 3)
    }

    @Test func acknowledgement_isSaved() async throws {
        let s = try setup()
        defer { s.h.tearDown() }
        s.app.acknowledgeRealPersonNotice(.openai, in: s.document)
        await s.document.flush()
        let loaded = try await BookStore(packageURL: s.document.store.packageURL).load()
        #expect(loaded.book.acknowledgements.realPersonPhotoNotice == [.openai])
    }

    // MARK: Pure helpers

    @Test func mentionCompletion_findsQueryFiltersAndInserts() throws {
        let pip = Asset.makeNew(type: .character, name: "Pip")
        let oak = Asset.makeNew(type: .place, name: "Granny Oak")
        let pippa = Asset.makeNew(type: .character, name: "Pippa")
        let lamp = Asset.makeNew(type: .object, name: "Lamp of Pip")
        let assets = [oak, pippa, pip, lamp]

        #expect(MentionCompletion.activeQuery(in: "no mention") == nil)
        #expect(MentionCompletion.activeQuery(in: "mail@pip")?.text == nil)
        #expect(MentionCompletion.activeQuery(in: "@")?.text == "")
        #expect(MentionCompletion.activeQuery(in: "@Pip ") == nil)
        #expect(MentionCompletion.activeQuery(in: "@Pip\nmore") == nil)
        let query = try #require(MentionCompletion.activeQuery(in: "@Granny Oak and @pi"))
        #expect(query.text == "pi")

        #expect(MentionCompletion.suggestions(for: "pi", assets: assets).map(\.name) == ["Pip", "Pippa", "Lamp of Pip"])
        #expect(MentionCompletion.suggestions(for: "", assets: assets).map(\.name)
                == ["Granny Oak", "Lamp of Pip", "Pip", "Pippa"])
        #expect(MentionCompletion.suggestions(for: "gr", assets: assets, limit: 1).map(\.name) == ["Granny Oak"])

        let text = MentionCompletion.insert(pip, replacing: query, in: "@Granny Oak and @pi")
        #expect(text == "@Granny Oak and @Pip ")
        // Sending tokenizes the picks, so a rename shows everywhere.
        let stored = MentionText.tokenizing(text + "yawning", assets: assets)
        #expect(MentionText.mentionedAssets(in: stored) == [oak.id, pip.id])
        var renamed = pip
        renamed.name = "Pippin"
        #expect(MentionText.displayText(stored, assets: [oak.id: oak, pip.id: renamed])
                == "Granny Oak and Pippin yawning")
    }

    @Test func checklistToggle_keepsOrder() {
        let a = AssetID(), b = AssetID(), c = AssetID()
        #expect(AssetChecklistEdit.toggled([a, b], c, on: true) == [a, b, c])
        #expect(AssetChecklistEdit.toggled([a, b], a, on: true) == [a, b])
        #expect(AssetChecklistEdit.toggled([a, b, c], b, on: false) == [a, c])
    }

    @Test func referenceSources_listOtherSessionsWithVersions_inOrder() throws {
        var content = Fixtures.book(pages: 2)
        let pip = Asset.makeNew(type: .character, name: "Pip")
        content.assets[pip.id] = pip
        for (id, owner) in pip.ownedSessions { content.sessions[id] = Session(id: id, owner: owner) }
        let v = Version(image: Fixtures.ref, pixelSize: PixelSize(width: 8, height: 8), source: .imported,
                        createdAt: Fixtures.date)
        let page1 = content.book.pageOrder[0], page2 = content.book.pageOrder[1]
        let box = Fixtures.imageBox.id
        let s1 = try #require(content.pages[page1]?.images[box]?.sessionID)
        let s2 = try #require(content.pages[page2]?.images[box]?.sessionID)
        let primary = try #require(pip.primary)
        for id in [s1, s2, primary.sessionID] { content.sessions[id]?.versions.append(v) }

        let sources = ReferenceSources.list(in: content, excluding: s1)
        #expect(sources.map(\.sessionID) == [s2, primary.sessionID])
        #expect(sources.map(\.label) == ["Page 2 · Image 1", "Pip · Primary"])
        #expect(ReferenceSources.chipLabel(VersionRef(sessionID: s2, versionID: v.id), in: content) == "Page 2 · Image 1 v1")
        #expect(ReferenceSources.chipLabel(VersionRef(sessionID: s2, versionID: VersionID()), in: content) == nil)
        let sleepy = try #require(pip.sheet?.items.last)
        #expect(BookDocument.ownerLabel(.sheetItem(pip.id, sleepy.id), in: content) == "Pip · Sleepy expression")
    }

    @Test func versionDetails_showAssetsLeftOutAndRealPerson() {
        let pip = Asset.makeNew(type: .character, name: "Pip")
        let oak = Asset.makeNew(type: .place, name: "Granny Oak")
        var provenance = Fixtures.provenance()
        provenance.intent.messageText = "\(MentionText.token(for: pip.id)) by \(MentionText.token(for: AssetID()))"
        provenance.assetRevisions = [pip.id: 3, oak.id: 1, AssetID(): 2]
        provenance.referencesOmitted = [SentReference(image: Fixtures.ref, role: "asset", label: "Pip (side)")]
        let generated = Version(image: Fixtures.ref, pixelSize: PixelSize(width: 8, height: 8), source: .generated,
                                createdAt: Fixtures.date, provenance: provenance)
        let rows = Dictionary(VersionDetailsContent.rows(for: generated, assets: [pip.id: pip, oak.id: oak])
            .map { ($0.label, $0.value) }, uniquingKeysWith: { a, _ in a })
        #expect(rows["Assets"] == "Granny Oak (revision 1), Pip (revision 3), 1 deleted asset")
        #expect(rows["Left out"] == "Pip (side) (asset)")
        #expect(rows["Your request"] == "Pip by (deleted asset)")

        let photo = Version(image: Fixtures.ref, pixelSize: PixelSize(width: 8, height: 8), source: .imported,
                            createdAt: Fixtures.date, depictsRealPerson: true)
        let photoRows = VersionDetailsContent.rows(for: photo)
        #expect(photoRows.contains(DetailRow(label: "Real person photo", value: "Yes")))
        let plain = Version(image: Fixtures.ref, pixelSize: PixelSize(width: 8, height: 8), source: .imported,
                            createdAt: Fixtures.date)
        #expect(!VersionDetailsContent.rows(for: plain).contains { $0.label == "Real person photo" })
    }

    @Test func realPersonNoticeText_hasPolicyLinkAndChildrenAdvice() {
        #expect(RealPersonNoticeText.policyURL(.openai)?.absoluteString == "https://openai.com/policies/privacy-policy/")
        let body = RealPersonNoticeText.body(.openai)
        #expect(body.contains("children under 13"))
        #expect(body.contains("zero-data-retention"))
        #expect(body.contains("describing the child in words"))
        #expect(body.contains("drawing"))
        #expect(RealPersonNoticeText.title(.openai).contains("OpenAI"))
    }
}
