import BBAICore
import BBModel
import BBStore
import Foundation
import Testing
@testable import BBAI
@testable import BBUI

// Phase 12 (A §7.8, PD §8.9): follow-ups from AppModel through the queue into open books,
// estimates with and without follow-ups, on-demand checks, the one-click fix and dismiss.

/// Returns scripted results (then "consistent") and records every request.
actor Phase12Vision: VisionProvider {
    nonisolated var id: ProviderID { .openai }
    private var outcomes: [Result<ConsistencyResult, ProviderError>]
    private(set) var requests: [ConsistencyRequest] = []

    init(_ outcomes: [Result<ConsistencyResult, ProviderError>] = []) { self.outcomes = outcomes }

    func checkConsistency(_ request: ConsistencyRequest) async throws(ProviderError) -> ConsistencyResult {
        requests.append(request)
        let outcome = outcomes.isEmpty ? .success(ConsistencyResult(consistent: true, differences: [])) : outcomes.removeFirst()
        return try outcome.get()
    }

    func count() -> Int { requests.count }
}

@MainActor
struct ConsistencyFlowTests {
    static let vision = CatalogTextModel(provider: .openai, id: "vision-test", displayName: "Vision Test", kind: .vision,
                                         consistency: ConsistencyThresholds(warnOnMajor: 1, warnOnMinor: 3))
    static let scarf = ConsistencyDifference(asset: "Pip", aspect: "scarf colour", observed: "blue", expected: "red",
                                             severity: .major)

    private struct Setup {
        var h: Phase9Harness
        var app: AppModel
        var vision: Phase12Vision
    }

    /// An app whose catalog has a vision model, with a fake vision provider, a fake estimator
    /// (one tenth of a cent per image) and fake prompt text.
    private func setup(vision: Phase12Vision = Phase12Vision(), wired: Bool = true) async throws -> Setup {
        let h = try Phase9Harness()
        var catalog = try ModelCatalog.bundled()
        catalog.textModels = [Self.vision]
        let app = AppModel(providers: [.openai: Phase9Provider()], catalog: catalog, libraryRoot: h.libraryRoot,
                           keychainService: "app.bookbook.tests-\(UUID())",
                           indexCacheURL: h.dir.appending(path: "library-index.json"), userDefaults: h.defaults,
                           thumbnails: ThumbnailCache(root: h.dir.appending(path: "Caches")), appSupport: h.appSupport,
                           visionProviders: wired ? [.openai: vision] : [:])
        app.consistencyEstimator = { _, count, _ in CostEstimate(amount: Decimal(count) / 1000) }
        app.correctionMessage = { "Keep everything the same, but: " + $0.map(\.expected).joined(separator: "; ") }
        await app.queue.setConsistencyInstructions { _, _, labels in ("SYS", "USER " + labels.joined(separator: ",")) }
        return Setup(h: h, app: app, vision: vision)
    }

    private func openBook(_ s: Setup) async throws -> (BookDocument, PageID, BoxID, SessionID) {
        let entry = try s.h.createBook()
        await s.app.refreshLibrary()
        let document = try await s.app.openBook(entry.id)
        let (page, box) = try Phase9Harness.firstImageBox(document.content)
        let session = try #require(document.content.pages[page]?.images[box]?.sessionID)
        return (document, page, box, session)
    }

    /// An imported picture (stored in the book's images, so a check can read it).
    private func importVersion(into session: SessionID, page: PageID, box: BoxID,
                               in document: BookDocument) async throws -> Version {
        let id = VersionID()
        let ref = try await document.store.storeImage(Data([1, 2, 3, 4]), contentType: "public.png")
        document.performIrreversible {
            BookMutations.appendImportedVersion(image: ref, pixelSize: PixelSize(width: 64, height: 64),
                                                page: page, box: box, to: &$0, versionID: id, now: Fixtures.date)
        }
        return try #require(document.content.sessions[session]?.version(id))
    }

    // MARK: Follow-ups

    @Test func generate_withSwitchOn_checksTheNewVersionAndWritesTheReport() async throws {
        let s = try await setup(vision: Phase12Vision([.success(ConsistencyResult(
            consistent: false, differences: [Self.scarf], usage: TokenUsage(inputTextTokens: 50)))]))
        defer { s.h.tearDown() }
        let (document, page, box, session) = try await openBook(s)
        #expect(s.app.generate(prompt: "Pip in a blue scarf", quality: .draft, includeStoryText: true, refines: nil,
                               attachedReferences: [], target: .pageBox(page, box), in: document))
        await until("report") { document.content.sessions[session]?.versions.first?.consistency != nil }
        let version = try #require(document.content.sessions[session]?.versions.first)
        #expect(document.content.sessions[session]?.versions.count == 1)
        #expect(version.source == .generated)
        #expect(version.provenance?.intent.checkConsistency == true)
        let report = try #require(version.consistency)
        #expect(report.warns && report.showsWarning)
        #expect(report.differences == [Self.scarf])
        #expect(report.sent.promptSent == "SYS\n\nUSER Image to check")
        let costs = await s.app.openBooks.costRecords(for: document.id)
        #expect(costs.map(\.kind) == [.image, .consistency])
        #expect(report.cost == costs.last?.id)
        // The check's estimate rode on the parent item; its ledger line has the check's own estimate.
        #expect(costs.last?.estimated == Decimal(1) / 1000)
        await until("queue empty") { s.app.queueSnapshot.entries.isEmpty }
    }

    @Test func switchOff_noFollowUpAndALowerEstimate() async throws {
        let s = try await setup()
        defer { s.h.tearDown() }
        let (document, page, box, session) = try await openBook(s)
        let on = try #require(s.app.estimate(prompt: "a fox", quality: .draft, includeStoryText: true, refines: nil,
                                             attachedReferences: [], target: .pageBox(page, box), in: document).amount)
        s.app.preferences.consistencyCheckEnabled = false
        let off = try #require(s.app.estimate(prompt: "a fox", quality: .draft, includeStoryText: true, refines: nil,
                                              attachedReferences: [], target: .pageBox(page, box), in: document).amount)
        #expect(on == off + Decimal(1) / 1000)

        #expect(s.app.generate(prompt: "a fox", quality: .draft, includeStoryText: true, refines: nil,
                               attachedReferences: [], target: .pageBox(page, box), in: document))
        await until("version") { document.content.sessions[session]?.versions.count == 1 }
        await until("queue empty") { s.app.queueSnapshot.entries.isEmpty }
        try await Task.sleep(for: .milliseconds(50))
        #expect(s.app.queueSnapshot.entries.isEmpty)
        #expect(await s.vision.count() == 0)
        #expect(document.content.sessions[session]?.versions.first?.consistency == nil)
        #expect(document.content.sessions[session]?.versions.first?.provenance?.intent.checkConsistency == false)
    }

    @Test func noVisionProvider_noFollowUpAndNoFollowUpCost() async throws {
        let s = try await setup(wired: false)
        defer { s.h.tearDown() }
        let (document, page, box, _) = try await openBook(s)
        #expect(!s.app.canCheckConsistency)
        let estimate = s.app.estimate(prompt: "a fox", quality: .draft, includeStoryText: true, refines: nil,
                                      attachedReferences: [], target: .pageBox(page, box), in: document)
        let own = s.app.ownEstimate(s.app.generationIntent(prompt: "a fox", quality: .draft, includeStoryText: true,
                                                           refines: nil),
                                    target: .pageBox(page, box), content: document.content)
        #expect(estimate == own)
    }

    @Test func batchEstimatesIncludeFollowUps() async throws {
        let s = try await setup()
        defer { s.h.tearDown() }
        var content = Fixtures.book(pages: 2)
        let pip = Asset.makeNew(type: .character, name: "Pip")
        content.assets[pip.id] = pip
        content.sessions[pip.sessionID] = Session(id: pip.sessionID, owner: pip.owner)
        let url = s.h.dir.appending(path: "Batch.bookbook", directoryHint: .isDirectory)
        try BookStore.create(content, at: url)
        let document = BookDocument(content: content, store: BookStore(packageURL: url))

        let draftOn = s.app.draftAllPlan(in: document)
        #expect(draftOn.items.allSatisfy { $0.consistencyFollowUp != nil && $0.intent.checkConsistency == true })
        // The item's own estimate (its ledger line) leaves the follow-up out; the plan total has it.
        #expect(draftOn.estimate == CostEstimate.total(draftOn.items.flatMap {
            [$0.estimate, $0.consistencyFollowUp!.estimate]
        }))
        s.app.preferences.consistencyCheckEnabled = false
        let draftOff = s.app.draftAllPlan(in: document)
        #expect(draftOff.items.allSatisfy { $0.consistencyFollowUp == nil && $0.intent.checkConsistency == false })
        let draftOnAmount = try #require(draftOn.estimate.amount), draftOffAmount = try #require(draftOff.estimate.amount)
        #expect(draftOnAmount > draftOffAmount)
    }

    // MARK: On demand

    @Test func onDemandCheckOfAnImportedVersion() async throws {
        let s = try await setup(vision: Phase12Vision([.success(ConsistencyResult(consistent: true, differences: []))]))
        defer { s.h.tearDown() }
        let (document, page, box, session) = try await openBook(s)
        let imported = try await importVersion(into: session, page: page, box: box, in: document)
        #expect(s.app.consistencyCheckEstimate(bookID: document.id, sessionID: session, versionID: imported.id).amount
            == Decimal(1) / 1000)
        s.app.pauseQueue()
        #expect(s.app.checkConsistency(bookID: document.id, sessionID: session, versionID: imported.id))
        await s.app.queueOperationsSettled()
        await until("pending") { s.app.isConsistencyCheckPending(versionID: imported.id) }
        #expect(!s.app.checkConsistency(bookID: document.id, sessionID: session, versionID: imported.id))
        let entry = try #require(s.app.consistencyCheckEntry(versionID: imported.id))
        #expect(entry.item.display.boxLabel.hasSuffix("Consistency check"))
        s.app.resumeQueue()
        await until("report") { document.content.sessions[session]?.version(imported.id)?.consistency != nil }
        let report = try #require(document.content.sessions[session]?.version(imported.id)?.consistency)
        #expect(!report.warns)
        #expect(document.content.sessions[session]?.version(imported.id)?.source == .imported)
        #expect(!s.app.isConsistencyCheckPending(versionID: imported.id))
    }

    @Test func failedCheckLeavesTheVersionUntouched() async throws {
        let s = try await setup(vision: Phase12Vision([.failure(.refused(stage: .input, categories: [], nil))]))
        defer { s.h.tearDown() }
        let (document, page, box, session) = try await openBook(s)
        let imported = try await importVersion(into: session, page: page, box: box, in: document)
        let before = document.content
        #expect(s.app.checkConsistency(bookID: document.id, sessionID: session, versionID: imported.id))
        await until("failed") {
            if case .failed = s.app.consistencyCheckEntry(versionID: imported.id)?.state { return true }
            return false
        }
        let entry = try #require(s.app.consistencyCheckEntry(versionID: imported.id))
        #expect(s.app.advice(for: entry) != nil)
        #expect(!s.app.isConsistencyCheckPending(versionID: imported.id))
        #expect(document.content == before)
    }

    @Test func checkOfADeletedVersionIsDropped() async throws {
        let s = try await setup()
        defer { s.h.tearDown() }
        let (document, page, box, session) = try await openBook(s)
        let imported = try await importVersion(into: session, page: page, box: box, in: document)
        s.app.pauseQueue()
        #expect(s.app.checkConsistency(bookID: document.id, sessionID: session, versionID: imported.id))
        await s.app.queueOperationsSettled()
        await until("pending") { s.app.isConsistencyCheckPending(versionID: imported.id) }
        document.performIrreversible { BookMutations.deleteVersion(imported.id, in: session, to: &$0) }
        s.app.resumeQueue()
        await until("dropped") { s.app.consistencyCheckEntry(versionID: imported.id) == nil }
        #expect(await s.vision.count() == 0)
        #expect(await s.app.openBooks.costRecords(for: document.id).isEmpty)
    }

    // MARK: One-click fix and dismiss

    @Test func oneClickFixRefinesTheVersionAsAConsistencyFix() async throws {
        let s = try await setup(vision: Phase12Vision([.success(ConsistencyResult(consistent: false,
                                                                                  differences: [Self.scarf]))]))
        defer { s.h.tearDown() }
        let (document, page, box, session) = try await openBook(s)
        #expect(s.app.generate(prompt: "Pip", quality: .draft, includeStoryText: false, refines: nil,
                               attachedReferences: [], target: .pageBox(page, box), in: document))
        await until("report") { document.content.sessions[session]?.versions.first?.consistency != nil }
        let checked = try #require(document.content.sessions[session]?.versions.first)
        let intent = try #require(s.app.consistencyFixIntent(bookID: document.id, sessionID: session,
                                                              versionID: checked.id))
        #expect(intent.messageText == "Keep everything the same, but: red")
        #expect(intent.refines == checked.id)
        #expect(intent.versionSource == .consistencyFix)
        #expect(intent.checkConsistency == true)
        #expect(intent.quality == .draft)
        #expect(!intent.includeStoryText)
        let target = GenerationTarget.pageBox(page, box)
        let withFollowUp = try #require(s.app.estimate(for: intent, target: target, in: document).amount)
        var noCheck = intent
        noCheck.checkConsistency = false
        #expect(withFollowUp > (try #require(s.app.estimate(for: noCheck, target: target, in: document).amount)))

        #expect(s.app.enqueueGeneration(intent, target: target, in: document))
        await until("fix delivered") { document.content.sessions[session]?.versions.count == 2 }
        let fix = try #require(document.content.sessions[session]?.versions.last)
        #expect(fix.source == .consistencyFix)
        #expect(fix.parent == checked.id)
        #expect(fix.provenance?.intent.versionSource == .consistencyFix)
        // The fix gets its own follow-up check.
        await until("fix checked") { document.content.sessions[session]?.versions.last?.consistency != nil }
        // Nothing to fix on a consistent version.
        #expect(s.app.consistencyFixIntent(bookID: document.id, sessionID: session, versionID: fix.id) == nil)
    }

    @Test func dismissHidesTheWarning() async throws {
        let s = try await setup()
        defer { s.h.tearDown() }
        let (document, page, box, session) = try await openBook(s)
        let imported = try await importVersion(into: session, page: page, box: box, in: document)
        #expect(!s.app.setConsistencyWarningDismissed(true, sessionID: session, versionID: imported.id, in: document))
        let report = ConsistencyReport(checkedAt: Fixtures.date, provider: .openai, model: "vision-test",
                                       consistent: false, differences: [Self.scarf], warns: true,
                                       sent: ConsistencySent(promptSent: "p", imagesSent: []))
        document.performIrreversible { content in
            BookMutations.applyConsistencyDelivery(
                GenerationDelivery(item: Self.checkItem(imported.id, book: document.id), outcome: .consistency(report)),
                to: &content)
        }
        #expect(document.content.sessions[session]?.version(imported.id)?.consistency?.showsWarning == true)
        #expect(s.app.setConsistencyWarningDismissed(true, sessionID: session, versionID: imported.id, in: document))
        #expect(document.content.sessions[session]?.version(imported.id)?.consistency?.showsWarning == false)
        #expect(!s.app.setConsistencyWarningDismissed(true, sessionID: session, versionID: imported.id, in: document))
    }

    static func checkItem(_ version: VersionID, book: BookID = BookID()) -> QueueItem {
        QueueItem(bookID: book, target: .pageBox(PageID(), BoxID()), messageID: MessageID(),
                  intent: GenerationIntent(messageText: "", refines: version, provider: .openai, model: "vision-test",
                                           quality: .draft),
                  kind: .consistencyCheck(version))
    }
}

// MARK: - Pure delivery rules

@MainActor
struct ConsistencyDeliveryTests {
    @Test func failedCheckChangesNothing_andAGoneVersionIsIgnored() throws {
        var content = Fixtures.book()
        let page = Fixtures.firstPage(content)
        let id = VersionID()
        _ = BookMutations.appendImportedVersion(image: Fixtures.ref, pixelSize: PixelSize(width: 8, height: 8), page: page,
                                                box: Fixtures.imageBox.id, to: &content, versionID: id, now: Fixtures.date)
        let before = content
        let item = ConsistencyFlowTests.checkItem(id)
        #expect(BookMutations.applyDelivery(GenerationDelivery(item: item, outcome: .failure(.refused(stage: .input, categories: [], nil))),
                                            storedImage: nil, to: &content, now: Fixtures.date).isEmpty)
        #expect(BookMutations.applyDelivery(GenerationDelivery(item: item, outcome: .failure(.cancelled)),
                                            storedImage: nil, to: &content, now: Fixtures.date).isEmpty)
        let report = ConsistencyReport(checkedAt: Fixtures.date, provider: .openai, model: "m", consistent: true,
                                       differences: [], warns: false, sent: ConsistencySent(promptSent: "", imagesSent: []))
        #expect(BookMutations.applyDelivery(GenerationDelivery(item: ConsistencyFlowTests.checkItem(VersionID()),
                                                               outcome: .consistency(report)),
                                            storedImage: nil, to: &content, now: Fixtures.date).isEmpty)
        #expect(content == before)
        let dirty = BookMutations.applyDelivery(GenerationDelivery(item: item, outcome: .consistency(report)),
                                                storedImage: nil, to: &content, now: Fixtures.date)
        #expect(!dirty.sessions.isEmpty)
        let sessionID = try #require(content.pages[page]?.images[Fixtures.imageBox.id]?.sessionID)
        #expect(content.sessions[sessionID]?.version(id)?.consistency == report)
        #expect(content.sessions[sessionID]?.versions.count == 1)
    }

    @Test func deliveriesUseTheQueuesVersionIDAndTheIntentsSource() throws {
        var content = Fixtures.book()
        let page = Fixtures.firstPage(content)
        var provenance = Fixtures.provenance()
        provenance.intent.versionSource = .consistencyFix
        let (_, item) = BookMutations.makeGeneration(intent: provenance.intent, bookID: content.book.id,
                                                     target: .pageBox(page, Fixtures.imageBox.id), now: Fixtures.date)
        let versionID = VersionID()
        _ = BookMutations.applyDelivery(GenerationDelivery(item: item, outcome: .success(result: Fixtures.result(),
                                                                                         provenance: provenance),
                                                           versionID: versionID),
                                        storedImage: Fixtures.ref, to: &content, now: Fixtures.date)
        let sessionID = try #require(content.pages[page]?.images[Fixtures.imageBox.id]?.sessionID)
        #expect(content.sessions[sessionID]?.versions.map(\.id) == [versionID])
        #expect(content.sessions[sessionID]?.versions.first?.source == .consistencyFix)

        // Asset sessions too.
        let pip = Asset.makeNew(type: .character, name: "Pip")
        content.assets[pip.id] = pip
        content.sessions[pip.sessionID] = Session(id: pip.sessionID, owner: pip.owner)
        let (_, assetItem) = BookMutations.makeGeneration(intent: provenance.intent, bookID: content.book.id,
                                                          target: .asset(pip.id), now: Fixtures.date)
        let assetVersion = VersionID()
        _ = BookMutations.applyDelivery(GenerationDelivery(item: assetItem, outcome: .success(result: Fixtures.result(),
                                                                                              provenance: provenance),
                                                           versionID: assetVersion),
                                        storedImage: Fixtures.ref, to: &content, now: Fixtures.date)
        #expect(content.sessions[pip.sessionID]?.version(assetVersion)?.source == .consistencyFix)
    }

    @Test func queueFileFromPhase9StillLoads() async throws {
        let h = try Phase9Harness()
        defer { h.tearDown() }
        let item = QueueItem(bookID: BookID(), target: .pageBox(PageID(), BoxID()), messageID: MessageID(),
                             intent: GenerationIntent(messageText: "a fox", provider: .openai,
                                                      model: "gpt-image-2.5-sunburst", quality: .draft))
        let json = try JSONSerialization.jsonObject(with: QueueFileStore.encoder().encode(item))
        var object = try #require(json as? [String: Any])
        for key in ["kind", "parent", "consistencyFollowUp"] { object.removeValue(forKey: key) }
        let file = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "entries": [["item": object, "wasRunning": false]]])
        try h.appSupport.write(file, to: AppSupportFiles.queueFileName)
        let loaded = try #require(await QueueFileStore(files: h.appSupport).load())
        #expect(loaded.entries.first?.item == item)
        #expect(loaded.entries.first?.item.kind == .image)
    }
}
