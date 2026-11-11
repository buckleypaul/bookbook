import BBAI
import BBAICore
import BBModel
import BBStore
import Foundation
import Testing
@testable import BBUI

private actor FakeLayoutProvider: LayoutProvider {
    nonisolated var id: ProviderID { .openai }
    private var outcomes: [Result<LayoutResult, ProviderError>]
    private(set) var requests: [LayoutRequest] = []

    /// Answers with each outcome in turn, repeating the last.
    init(_ outcomes: Result<LayoutResult, ProviderError>...) { self.outcomes = outcomes }

    func generateLayout(_ request: LayoutRequest) async throws(ProviderError) -> LayoutResult {
        requests.append(request)
        let outcome = outcomes.count > 1 ? outcomes.removeFirst() : outcomes[0]
        return try outcome.get()
    }
}

/// The Layouts chat (PD §8.4, A §7.7). Uses a fake backend for the prompts, estimate and
/// normalizer, so these tests don't depend on the BBAI implementations; the last test
/// exercises the real ones.
@MainActor
struct TemplateChatModelTests {
    private static let draft = TemplateDraft(name: "Top picture", boxes: [
        DraftBox(kind: .image, x: 0, y: 0, width: 1, height: 0.66),
        DraftBox(kind: .text, x: 0.1, y: 0.7, width: 0.8, height: 0.2, cornerRadius: 12, backgroundColor: "#FFF8E7"),
    ])

    private static let revisedDraft = TemplateDraft(name: "ignored", boxes: [
        DraftBox(kind: .image, x: 0, y: 0, width: 1, height: 1),
        DraftBox(kind: .text, x: 0.1, y: 0.8, width: 0.8, height: 0.15),
    ])

    private static let backend = TemplateChatBackend(
        buildRequest: { description, _, _, _, model in
            LayoutRequest(model: model, system: "system", user: "design: " + description)
        },
        buildRevision: { instruction, history, current, _, model in
            LayoutRequest(model: model, system: "system",
                          user: "revise \(current.boxes.count): \((history + [instruction]).joined(separator: " | "))")
        },
        estimate: { _, _ in CostEstimate(amount: 0.01, priceListAsOf: "test") },
        revise: { current, draft, _ throws(TemplateDraftError) in
            guard !draft.boxes.isEmpty else { throw .noBoxes }
            var template = current
            template.boxes = draft.boxes.enumerated().map { index, raw in
                Box(id: index < current.boxes.count ? current.boxes[index].id : BoxID(),
                    frame: NormalizedRect(x: raw.x, y: raw.y, width: raw.width, height: raw.height),
                    content: raw.kind == .image ? .image : .text(TextBoxStyle()))
            }
            return template
        })

    private struct Setup {
        var h: Phase9Harness
        var app: AppModel
        var entry: LibraryEntry
        var document: BookDocument
        var undo: UndoManager
    }

    private func setup(_ provider: (any LayoutProvider)?) async throws -> Setup {
        let h = try Phase9Harness()
        // The bundled catalog doesn't load text models until the BBAI lane merges: inject one.
        var catalog = try ModelCatalog.bundled()
        if catalog.textModel(provider: .openai, id: "gpt-6-luna") == nil {
            catalog.textModels.append(CatalogTextModel(provider: .openai, id: "gpt-6-luna", displayName: "GPT-6 Luna",
                                                       kind: .text))
        }
        let app = AppModel(providers: [:], catalog: catalog, libraryRoot: h.libraryRoot, keychainService: "app.bookbook.tests-\(UUID())",
                           indexCacheURL: h.dir.appending(path: "library-index.json"), userDefaults: h.defaults,
                           thumbnails: ThumbnailCache(root: h.dir.appending(path: "Caches")), appSupport: h.appSupport)
        app.layoutProvider = provider
        let entry = try h.createBook()
        let document = try await app.openBook(entry.id)
        let undo = UndoManager()
        undo.groupsByEvent = false
        document.undoManager = undo
        return Setup(h: h, app: app, entry: entry, document: document, undo: undo)
    }

    private func chat(_ s: Setup, backend: TemplateChatBackend = backend) -> (TemplateChatModel, TemplateEditorModel) {
        let editor = TemplateEditorModel(document: s.document)
        return (TemplateChatModel(document: s.document, editor: editor, backend: backend), editor)
    }

    /// A blank single template, opened, as "New Layout with AI" leaves it.
    private func blank(_ s: Setup, _ chat: TemplateChatModel, _ editor: TemplateEditorModel,
                       kind: TemplateKind = .single) throws -> TemplateID {
        grouped(s) { chat.newTemplateWithAI(kind: kind) }
        return try #require(editor.templateID)
    }

    /// The undo manager doesn't group by event here: every edit needs an explicit group.
    private func grouped(_ s: Setup, _ body: () -> Void) {
        s.undo.beginUndoGrouping()
        body()
        s.undo.endUndoGrouping()
    }

    private func send(_ s: Setup, _ chat: TemplateChatModel, _ text: String, to id: TemplateID,
                      confirmed: Bool = true, isRetry: Bool = false) async {
        s.undo.beginUndoGrouping()
        await chat.send(text, to: id, app: s.app, confirmed: confirmed, isRetry: isRetry)
        s.undo.endUndoGrouping()
    }

    @Test func newWithAI_opensBlankTemplate_andAsksForFocus() async throws {
        let s = try await setup(FakeLayoutProvider(.success(LayoutResult(draft: Self.draft))))
        defer { s.h.tearDown() }
        let (chat, editor) = chat(s)
        chat.pane = .box
        let id = try blank(s, chat, editor)
        #expect(s.document.content.templates[id]?.boxes.isEmpty == true)
        #expect(chat.pane == .chat)
        #expect(chat.wantsComposerFocus)
    }

    @Test func firstMessage_designs_thenRevises_keepingBoxIDs_eachOneUndoStep() async throws {
        let usage = TokenUsage(inputTextTokens: 500, outputTextTokens: 300)
        let provider = FakeLayoutProvider(
            .success(LayoutResult(draft: Self.draft, usage: usage, parametersSent: ["model": "gpt-6-luna"])),
            .success(LayoutResult(draft: Self.revisedDraft)))
        let s = try await setup(provider)
        defer { s.h.tearDown() }
        let (chat, editor) = chat(s)
        let id = try blank(s, chat, editor)

        await send(s, chat, "Big picture across the top", to: id)

        let designed = try #require(s.document.content.templates[id])
        #expect(designed.name == "Top picture")
        #expect(designed.boxes.count == 2)
        var thread = chat.messages(for: id)
        #expect(thread.map(\.role) == [.user, .assistant])
        #expect(thread[0].text == "Big picture across the top")
        #expect(thread[1].snapshot == designed)
        #expect(thread[1].sent?.user == "design: Big picture across the top")
        #expect(thread[1].sent?.parametersSent["model"] == "gpt-6-luna")
        #expect(chat.state(for: id) == .idle)

        await send(s, chat, "Make the picture full-bleed", to: id)

        let revised = try #require(s.document.content.templates[id])
        #expect(revised.name == "Top picture") // a revision keeps the name
        #expect(revised.boxes.map(\.id) == designed.boxes.map(\.id))
        #expect(revised.boxes[0].frame.height == 1)
        thread = chat.messages(for: id)
        #expect(thread.count == 4)
        #expect(thread[3].sent?.user == "revise 2: Big picture across the top | Make the picture full-bleed")

        let records = await s.app.openBooks.costRecords(for: s.entry.id)
        #expect(records.count == 2)
        #expect(records.allSatisfy { $0.kind == .template && $0.status == .completed })
        let expected = s.app.prices.calculator.actualCost(of: usage, provider: .openai, model: "gpt-6-luna")
        #expect(records.contains { $0.actual == expected })

        // Restore the first reply, then undo the restore and the revision.
        #expect(chat.canRestore(thread[1], in: id))
        grouped(s) { chat.restore(thread[1], in: id) }
        #expect(s.document.content.templates[id]?.boxes == designed.boxes)
        #expect(!chat.canRestore(thread[1], in: id))
        s.undo.undo()
        #expect(s.document.content.templates[id]?.boxes == revised.boxes)
        s.undo.undo()
        #expect(s.document.content.templates[id]?.boxes == designed.boxes)
        s.undo.undo()
        #expect(s.document.content.templates[id]?.boxes.isEmpty == true)
    }

    @Test func replyForANonOpenTemplate_appliesToThatTemplate() async throws {
        let s = try await setup(FakeLayoutProvider(.success(LayoutResult(draft: Self.draft))))
        defer { s.h.tearDown() }
        let (chat, editor) = chat(s)
        let id = try blank(s, chat, editor)
        grouped(s) { editor.newTemplate(kind: .single) }
        let other = try #require(editor.templateID)
        #expect(other != id)

        await send(s, chat, "Top picture", to: id)

        #expect(s.document.content.templates[id]?.boxes.count == 2)
        #expect(s.document.content.templates[other]?.boxes.isEmpty == true)
        #expect(editor.templateID == other)
    }

    @Test func revisingAnUncopiedPreset_copiesItIn() async throws {
        let s = try await setup(FakeLayoutProvider(.success(LayoutResult(draft: Self.revisedDraft))))
        defer { s.h.tearDown() }
        let (chat, editor) = chat(s)
        let preset = try #require(Presets.bundledTemplates.first {
            $0.kind == .single && !$0.boxes.isEmpty && s.document.content.templates[$0.id] == nil
        })
        editor.open(preset.id)
        #expect(editor.isUncopiedPreset)

        await send(s, chat, "Full-bleed picture", to: preset.id)

        #expect(s.document.content.templates[preset.id] != nil)
        #expect(chat.messages(for: preset.id).last?.snapshot != nil)
    }

    @Test func refusal_addsAdviceReply_keepsWhatWasSent_recordsFreeLine_andRetries() async throws {
        let provider = FakeLayoutProvider(.failure(.refused(stage: .output, categories: [], nil)),
                                          .success(LayoutResult(draft: Self.draft)))
        let s = try await setup(provider)
        defer { s.h.tearDown() }
        let (chat, editor) = chat(s)
        let id = try blank(s, chat, editor)

        await send(s, chat, "Top picture", to: id)

        let reply = try #require(chat.messages(for: id).last)
        #expect(reply.failure?.headline.isEmpty == false)
        #expect(reply.sent?.system == "system")
        #expect(reply.retryInstruction == "Top picture")
        #expect(s.document.content.templates[id]?.boxes.isEmpty == true)
        let records = await s.app.openBooks.costRecords(for: s.entry.id)
        let record = try #require(records.first)
        #expect(record.status == .failed && record.actual == 0 && record.basis == .actual)

        await send(s, chat, "Top picture", to: id, isRetry: true)
        // The retry doesn't repeat the instruction in the thread.
        #expect(chat.messages(for: id).map(\.role) == [.user, .assistant, .assistant])
        #expect(s.document.content.templates[id]?.boxes.count == 2)
    }

    @Test func doubleSubmit_sendsOnce() async throws {
        // A refusal makes no document edit, so the ungrouped submit tasks are safe here.
        let provider = FakeLayoutProvider(.failure(.refused(stage: .output, categories: [], nil)))
        let s = try await setup(provider)
        defer { s.h.tearDown() }
        let (chat, editor) = chat(s)
        let id = try blank(s, chat, editor)

        chat.submit("Top picture", to: id, app: s.app, confirmed: true)
        #expect(chat.isRunning(id))
        chat.submit("Top picture", to: id, app: s.app, confirmed: true)
        while chat.isRunning(id) { await Task.yield() }

        #expect(await provider.requests.count == 1)
        #expect(chat.messages(for: id).map(\.role) == [.user, .assistant])
    }

    @Test func noBoxes_failsWithoutChangingTheTemplate_butStillBills() async throws {
        let provider = FakeLayoutProvider(.success(LayoutResult(draft: TemplateDraft(name: "Empty", boxes: []))))
        let s = try await setup(provider)
        defer { s.h.tearDown() }
        let (chat, editor) = chat(s)
        let id = try blank(s, chat, editor)

        await send(s, chat, "Top picture", to: id)

        #expect(chat.messages(for: id).last?.failure != nil)
        #expect(s.document.content.templates[id]?.boxes.isEmpty == true)
        let records = await s.app.openBooks.costRecords(for: s.entry.id)
        #expect(records.map(\.status) == [.completed])
    }

    @Test func noProvider_failsWithoutALedgerLine() async throws {
        let s = try await setup(nil)
        defer { s.h.tearDown() }
        let (chat, editor) = chat(s)
        let id = try blank(s, chat, editor)
        await send(s, chat, "Top picture", to: id)
        #expect(chat.messages(for: id).last?.failure != nil)
        #expect(await s.app.openBooks.costRecords(for: s.entry.id).isEmpty)
    }

    @Test func missingKey_isAdvice_withNoLedgerLine() async throws {
        let s = try await setup(FakeLayoutProvider(.failure(.missingKey)))
        defer { s.h.tearDown() }
        let (chat, editor) = chat(s)
        let id = try blank(s, chat, editor)
        await send(s, chat, "Top picture", to: id)
        let reply = try #require(chat.messages(for: id).last)
        #expect(reply.failure != nil)
        #expect(reply.sent == nil) // nothing left the machine, so nothing was sent
        #expect(await s.app.openBooks.costRecords(for: s.entry.id).isEmpty)
    }

    @Test func offline_isAdvice_withNoLedgerLine() async throws {
        // The queue's ledger rule: offline means nothing reached the provider, so nothing is billed.
        let s = try await setup(FakeLayoutProvider(.failure(.offline)))
        defer { s.h.tearDown() }
        let (chat, editor) = chat(s)
        let id = try blank(s, chat, editor)
        await send(s, chat, "Top picture", to: id)
        #expect(chat.messages(for: id).last?.failure != nil)
        #expect(await s.app.openBooks.costRecords(for: s.entry.id).isEmpty)
    }

    @Test func timeout_recordsTheEstimateAsFailed() async throws {
        let s = try await setup(FakeLayoutProvider(.failure(.timeout)))
        defer { s.h.tearDown() }
        let (chat, editor) = chat(s)
        let id = try blank(s, chat, editor)
        await send(s, chat, "Top picture", to: id)
        let record = try #require(await s.app.openBooks.costRecords(for: s.entry.id).first)
        #expect(record.kind == .template && record.status == .failed && record.basis == .estimate)
        #expect(record.actual == nil)
    }

    @Test func aboveThreshold_asksBeforeSending_andAddsNothingUntilSent() async throws {
        let provider = FakeLayoutProvider(.success(LayoutResult(draft: Self.draft)))
        let s = try await setup(provider)
        defer { s.h.tearDown() }
        s.app.preferences.confirmThreshold = 0
        let (chat, editor) = chat(s)
        let id = try blank(s, chat, editor)

        await send(s, chat, "Top picture", to: id, confirmed: false)
        guard case let .confirming(_, _, instruction, isRetry) = chat.state(for: id) else {
            Issue.record("state \(chat.state(for: id))"); return
        }
        #expect(instruction == "Top picture" && !isRetry)
        #expect(chat.messages(for: id).isEmpty)
        #expect(await provider.requests.isEmpty)

        chat.cancelConfirmation(id)
        #expect(chat.state(for: id) == .idle)

        await send(s, chat, "Top picture", to: id)
        #expect(await provider.requests.count == 1)
        #expect(chat.messages(for: id).count == 2)
    }

    @Test func realBackend_designsASpread_thenRevisesIt() async throws {
        let provider = FakeLayoutProvider(.success(LayoutResult(draft: Self.draft)),
                                          .success(LayoutResult(draft: Self.revisedDraft)))
        let s = try await setup(provider)
        defer { s.h.tearDown() }
        let (chat, editor) = chat(s, backend: .live)
        let id = try blank(s, chat, editor, kind: .spread)
        #expect(chat.request("Wide picture", for: id, app: s.app) != nil)
        #expect(chat.estimate("Wide picture", for: id, app: s.app)?.amount != nil)

        await send(s, chat, "Wide picture", to: id)
        let designed = try #require(s.document.content.templates[id])
        #expect(designed.kind == .spread && designed.boxes.count == 2)

        let revision = try #require(chat.request("Make it full-bleed", for: id, app: s.app))
        #expect(revision.user.contains("Wide picture") && revision.user.contains("Make it full-bleed"))
        await send(s, chat, "Make it full-bleed", to: id)
        let revised = try #require(s.document.content.templates[id])
        #expect(revised.boxes.map(\.id) == designed.boxes.map(\.id))
    }
}
