import BBAI
import BBAICore
import BBModel
import BBStore
import Foundation
import SwiftUI
import Testing
@testable import BBUI

/// Phase 10: generation for asset targets, the real-person notice check,
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
        content.sessions[pip.sessionID] = Session(id: pip.sessionID, owner: pip.owner)
        let url = h.dir.appending(path: "Assets.bookbook", directoryHint: .isDirectory)
        try BookStore.create(content, at: url)
        let document = BookDocument(content: content, store: BookStore(packageURL: url))
        return Setup(h: h, app: h.makeApp(), document: document, pip: pip)
    }

    @Test func generate_forAssetTarget_appendsPendingMessageWithAttachments() throws {
        let s = try setup()
        defer { s.h.tearDown() }
        let ref = VersionRef(sessionID: SessionID(), versionID: VersionID())
        #expect(s.app.generate(prompt: "  Pip, front view  ", quality: .draft, includeStoryText: false, refines: nil,
                               attachedReferences: [ref], target: .asset(s.pip.id), in: s.document))
        let message = try #require(s.document.content.sessions[s.pip.sessionID]?.messages.first)
        #expect(message.text == "Pip, front view")
        #expect(message.attachedReferences == [ref])
        #expect(message.queueItemID != nil)
        #expect(s.app.isPending(message, in: s.pip.owner))
        // Empty prompts and missing targets queue nothing.
        #expect(!s.app.generate(prompt: " ", quality: .draft, includeStoryText: false, refines: nil,
                                attachedReferences: [], target: .asset(s.pip.id), in: s.document))
        #expect(!s.app.generate(prompt: "x", quality: .draft, includeStoryText: false, refines: nil,
                                attachedReferences: [], target: .asset(AssetID()), in: s.document))
    }

    @Test func pageGenerate_stillWritesToTheBoxSession() throws {
        let s = try setup()
        defer { s.h.tearDown() }
        let page = Fixtures.firstPage(s.document.content)
        #expect(s.app.generate(prompt: "a fox", quality: .draft, includeStoryText: true, refines: nil,
                               attachedReferences: [], target: .pageBox(page, Fixtures.imageBox.id), in: s.document))
        let sessionID = try #require(s.document.content.pages[page]?.images[Fixtures.imageBox.id]?.sessionID)
        #expect(s.document.content.sessions[sessionID]?.messages.map(\.text) == ["a fox"])
    }

    @Test func realPersonNotice_dependsOnAssemblerAndAcknowledgement() throws {
        let s = try setup()
        defer { s.h.tearDown() }
        // A real-person photo chosen as Pip's image, Pip ticked on the page.
        let photo = Version(image: Fixtures.ref, pixelSize: PixelSize(width: 1024, height: 1024), source: .imported,
                            createdAt: Fixtures.date, depictsRealPerson: true)
        s.document.performIrreversible { content in
            BookMutations.appendImportedAssetVersion(image: Fixtures.ref, pixelSize: photo.pixelSize,
                                                     owner: s.pip.owner,
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

    /// Review fix: Draft All runs the same real-person check as a single send.
    @Test func batches_needTheRealPersonNotice_untilAcknowledged() throws {
        let s = try setup()
        defer { s.h.tearDown() }
        s.document.performIrreversible { content in
            BookMutations.appendImportedAssetVersion(image: Fixtures.ref, pixelSize: PixelSize(width: 1024, height: 1024),
                                                     owner: s.pip.owner,
                                                     depictsRealPerson: true, to: &content, now: Fixtures.date)
        }
        let page = Fixtures.firstPage(s.document.content)
        s.document.perform(.setAssetChecklist(page: page, [s.pip.id]))

        let draft = s.app.draftAllPlan(in: s.document)
        #expect(draft.count > 0)
        #expect(s.app.realPersonNoticeNeeded(for: draft.items, in: s.document) == .openai)

        s.app.acknowledgeRealPersonNotice(.openai, in: s.document)
        #expect(s.app.realPersonNoticeNeeded(for: draft.items, in: s.document) == nil)
        #expect(s.app.realPersonNoticeNeeded(for: [], in: s.document) == nil)
    }

    /// Review fix: the enqueue paths enforce the notice themselves (A §11), so a book that
    /// changed while the cost alert was up, or a caller that skipped the check, sends nothing.
    @Test func enqueue_refusesAnUnacknowledgedRealPersonPhoto() async throws {
        let s = try setup()
        defer { s.h.tearDown() }
        s.document.performIrreversible { content in
            BookMutations.appendImportedAssetVersion(image: Fixtures.ref, pixelSize: PixelSize(width: 1024, height: 1024),
                                                     owner: s.pip.owner,
                                                     depictsRealPerson: true, to: &content, now: Fixtures.date)
        }
        let page = Fixtures.firstPage(s.document.content)
        s.document.perform(.setAssetChecklist(page: page, [s.pip.id]))
        let target = GenerationTarget.pageBox(page, Fixtures.imageBox.id)
        let intent = s.app.generationIntent(prompt: "Pip in the garden", quality: .draft, includeStoryText: true,
                                            refines: nil)
        #expect(s.app.realPersonNoticeNeeded(intent: intent, target: target, in: s.document) == .openai)
        let size = PixelSize(width: 1024, height: 1024)
        let provenance = Provenance(provider: .openai, model: intent.model, quality: .draft, outputSize: size,
                                    promptSent: "Pip", styleRevision: 0, storyTextIncluded: true, intent: intent)
        let generated = Version(image: Fixtures.ref, pixelSize: size, source: .generated, createdAt: Fixtures.date,
                                provenance: provenance)
        let draft = s.app.draftAllPlan(in: s.document)
        func messages() -> Int { s.document.content.sessions.values.reduce(0) { $0 + $1.messages.count } }
        let before = messages()

        #expect(!s.app.generate(prompt: "Pip in the garden", quality: .draft, includeStoryText: true, refines: nil,
                                attachedReferences: [], target: target, in: s.document))
        #expect(!s.app.enqueueGeneration(intent, target: target, in: s.document))
        #expect(!s.app.regenerate(generated, target: target, in: s.document))
        #expect(!s.app.enqueueDraftAll(draft, in: s.document))
        #expect(messages() == before, "nothing appended")
        await s.app.queueOperationsSettled()
        #expect(await s.app.queue.snapshot().entries.isEmpty, "nothing enqueued")

        s.app.acknowledgeRealPersonNotice(.openai, in: s.document)
        #expect(s.app.enqueueGeneration(intent, target: target, in: s.document))
        #expect(s.app.regenerate(generated, target: target, in: s.document))
        #expect(messages() == before + 2)
    }

    /// Holds a flow's `pending` state for tests (what `@State` holds in the views). Only touched
    /// from these main-actor tests; `Binding`'s closures are `@Sendable`, hence unchecked.
    private final class PendingBox<Action: Sendable>: @unchecked Sendable {
        var value: PendingConfirmation<Action>?
        var binding: Binding<PendingConfirmation<Action>?> {
            Binding(get: { self.value }, set: { self.value = $0 })
        }
    }

    /// Follow-up fix: the notice becomes needed while the cost alert is up (a real-person photo
    /// arrives). Confirming shows the notice instead of silently doing nothing; continuing on it
    /// sends the same request without asking about the cost again.
    @Test func confirmingAfterTheNoticeBecameNeeded_showsTheNoticeThenSendsTheSameRequest() async throws {
        let s = try setup()
        defer { s.h.tearDown() }
        let page = Fixtures.firstPage(s.document.content)
        s.document.perform(.setAssetChecklist(page: page, [s.pip.id]))
        let target = GenerationTarget.pageBox(page, Fixtures.imageBox.id)
        let intent = s.app.generationIntent(prompt: "Pip in the garden", quality: .draft, includeStoryText: true,
                                            refines: nil)
        #expect(s.app.realPersonNoticeNeeded(intent: intent, target: target, in: s.document) == nil)

        let box = PendingBox<GenerationIntent>()
        var performed: [GenerationIntent] = []
        var enqueued: [Bool] = []
        let app = s.app, document = s.document
        let flow = GenerationConfirmFlow(app: app, document: document, pending: box.binding,
                                         notice: { app.realPersonNoticeNeeded(intent: $0, target: target, in: document) },
                                         estimate: { app.estimate(for: $0, target: target, in: document) },
                                         perform: {
                                             performed.append($0)
                                             enqueued.append(app.enqueueGeneration($0, target: target, in: document))
                                         })
        func messages() -> Int { s.document.content.sessions.values.reduce(0) { $0 + $1.messages.count } }
        let before = messages()

        // The cost alert is up; meanwhile Pip's image becomes a real-person photo.
        let alert = PendingConfirmation(action: intent, step: .cost("About $0.01"))
        box.value = alert
        s.document.performIrreversible { content in
            BookMutations.appendImportedAssetVersion(image: Fixtures.ref, pixelSize: PixelSize(width: 1024, height: 1024),
                                                     owner: s.pip.owner,
                                                     depictsRealPerson: true, to: &content, now: Fixtures.date)
        }
        #expect(s.app.realPersonNoticeNeeded(intent: intent, target: target, in: s.document) == .openai)

        flow.confirmCost(alert)
        let notice = try #require(box.value)
        #expect(notice.noticeProvider == .openai, "routed to the notice")
        #expect(notice.costConfirmed)
        #expect(notice.action == intent)
        #expect(performed.isEmpty)
        #expect(messages() == before, "nothing appended")
        await s.app.queueOperationsSettled()
        #expect(await s.app.queue.snapshot().entries.isEmpty, "nothing enqueued")

        // Continuing on the notice records the acknowledgement and sends the request.
        flow.acknowledge(notice)
        #expect(box.value == nil, "no second cost alert")
        #expect(s.document.content.book.acknowledgements.realPersonPhotoNotice == [.openai])
        #expect(performed == [intent], "the same request")
        #expect(enqueued == [true])
        #expect(messages() == before + 1)
        await s.app.queueOperationsSettled()
        #expect(await s.app.queue.snapshot().entries.map(\.item.intent) == [intent])
    }

    /// Starting a flow that needs the notice shows it first and performs nothing.
    @Test func startingAFlowThatNeedsTheNotice_showsItFirst() throws {
        let s = try setup()
        defer { s.h.tearDown() }
        s.document.performIrreversible { content in
            BookMutations.appendImportedAssetVersion(image: Fixtures.ref, pixelSize: PixelSize(width: 1024, height: 1024),
                                                     owner: s.pip.owner,
                                                     depictsRealPerson: true, to: &content, now: Fixtures.date)
        }
        let page = Fixtures.firstPage(s.document.content)
        s.document.perform(.setAssetChecklist(page: page, [s.pip.id]))
        let target = GenerationTarget.pageBox(page, Fixtures.imageBox.id)
        let intent = s.app.generationIntent(prompt: "Pip", quality: .draft, includeStoryText: true, refines: nil)
        let box = PendingBox<GenerationIntent>()
        var performed = 0
        let app = s.app, document = s.document
        let flow = GenerationConfirmFlow(app: app, document: document, pending: box.binding,
                                         notice: { app.realPersonNoticeNeeded(intent: $0, target: target, in: document) },
                                         estimate: { _ in .unknown }, perform: { _ in performed += 1 })
        flow.start(intent)
        #expect(box.value?.noticeProvider == .openai)
        #expect(box.value?.costConfirmed == false)
        #expect(performed == 0)
    }

    /// Review fix: a refused request whose report sent a real-person photo gets rule 1's advice.
    @Test func advice_forARefusalThatSentARealPersonPhoto() throws {
        let s = try setup()
        defer { s.h.tearDown() }
        let app = s.app
        let intent = GenerationIntent(messageText: "Pip", provider: .openai, model: "gpt-image-2.5-sunburst",
                                      quality: .draft)
        let item = QueueItem(bookID: BookID(), target: .asset(AssetID()), messageID: MessageID(), intent: intent)
        func entry(realPerson: Bool) -> QueueEntry {
            let report = AssemblyReport(
                promptText: "A calm scene.",
                referencesSent: [SentReference(image: Fixtures.ref, role: "photo", label: "Reference photo",
                                               depictsRealPerson: realPerson)],
                storyTextIncluded: false, styleRevision: 0)
            let failure = QueueFailure(error: .refused(stage: .input, categories: [], nil), report: report,
                                       attempts: 1, failedAt: Fixtures.date)
            return QueueEntry(item: item, state: .failed(failure))
        }
        let photo = "Describe the child in words instead of uploading a photo."
        #expect(app.advice(for: entry(realPerson: true))?.fixes == [photo])
        #expect(app.advice(for: entry(realPerson: false))?.fixes.contains(photo) == false)
    }

    @Test func batchNotice_oneNeedingItemAmongCleanOnes_andMixedProviders() throws {
        let s = try setup()
        defer { s.h.tearDown() }
        s.document.performIrreversible { content in
            BookMutations.appendImportedAssetVersion(image: Fixtures.ref, pixelSize: PixelSize(width: 1024, height: 1024),
                                                     owner: s.pip.owner,
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
        content.sessions[pip.sessionID] = Session(id: pip.sessionID, owner: pip.owner)
        let v = Version(image: Fixtures.ref, pixelSize: PixelSize(width: 8, height: 8), source: .imported,
                        createdAt: Fixtures.date)
        let page1 = content.book.pageOrder[0], page2 = content.book.pageOrder[1]
        let box = Fixtures.imageBox.id
        let s1 = try #require(content.pages[page1]?.images[box]?.sessionID)
        let s2 = try #require(content.pages[page2]?.images[box]?.sessionID)
        for id in [s1, s2, pip.sessionID] { content.sessions[id]?.versions.append(v) }

        let sources = ReferenceSources.list(in: content, excluding: s1)
        #expect(sources.map(\.sessionID) == [s2, pip.sessionID])
        #expect(sources.map(\.label) == ["Page 2 · Image 1", "Pip"])
        #expect(ReferenceSources.chipLabel(VersionRef(sessionID: s2, versionID: v.id), in: content) == "Page 2 · Image 1 v1")
        #expect(ReferenceSources.chipLabel(VersionRef(sessionID: s2, versionID: VersionID()), in: content) == nil)
        #expect(BookDocument.ownerLabel(pip.owner, in: content) == "Pip")
        #expect(AssetQueueDisplay.display(pip.owner, in: content).pageLabel == "Pip")
    }

    @Test func versionDetails_showAssetsLeftOutAndRealPerson() {
        let pip = Asset.makeNew(type: .character, name: "Pip")
        let oak = Asset.makeNew(type: .place, name: "Granny Oak")
        var provenance = Fixtures.provenance()
        provenance.intent.messageText = "\(MentionText.token(for: pip.id)) by \(MentionText.token(for: AssetID()))"
        provenance.assetRevisions = [pip.id: 3, oak.id: 1, AssetID(): 2]
        provenance.referencesOmitted = [SentReference(image: Fixtures.ref, role: "asset", label: "Pip")]
        let generated = Version(image: Fixtures.ref, pixelSize: PixelSize(width: 8, height: 8), source: .generated,
                                createdAt: Fixtures.date, provenance: provenance)
        let rows = Dictionary(VersionDetailsContent.rows(for: generated, assets: [pip.id: pip, oak.id: oak])
            .map { ($0.label, $0.value) }, uniquingKeysWith: { a, _ in a })
        #expect(rows["Assets"] == "Granny Oak (revision 1), Pip (revision 3), 1 deleted asset")
        #expect(rows["Left out"] == "Pip (asset)")
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
