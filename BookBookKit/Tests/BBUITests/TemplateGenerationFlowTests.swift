import BBAI
import BBAICore
import BBModel
import BBStore
import Foundation
import Testing
@testable import BBUI

private actor FakeLayoutProvider: LayoutProvider {
    nonisolated var id: ProviderID { .openai }
    private let outcome: Result<LayoutResult, ProviderError>
    private(set) var requests: [LayoutRequest] = []

    init(_ outcome: Result<LayoutResult, ProviderError>) { self.outcome = outcome }

    func generateLayout(_ request: LayoutRequest) async throws(ProviderError) -> LayoutResult {
        requests.append(request)
        return try outcome.get()
    }
}

/// The "Generate layout with AI" flow (A §7.7). Uses a fake backend for the prompt, estimate and
/// normalizer, so these tests don't depend on the BBAI lane's implementations; the last test
/// exercises the real ones and runs only when `BOOKBOOK_PHASE12_BBAI=1` (after the lanes merge).
@MainActor
struct TemplateGenerationFlowTests {
    private static let draft = TemplateDraft(name: "Top picture", boxes: [
        DraftBox(kind: .image, x: 0, y: 0, width: 1, height: 0.66),
        DraftBox(kind: .text, x: 0.1, y: 0.7, width: 0.8, height: 0.2, cornerRadius: 12, backgroundColor: "#FFF8E7"),
    ])

    private static let backend = TemplateGenerationBackend(
        buildRequest: { description, _, _, _, model in
            LayoutRequest(model: model, system: "system", user: description)
        },
        estimate: { _, _ in CostEstimate(amount: 0.01, priceListAsOf: "test") },
        normalize: { draft, kind, _ throws(TemplateDraftError) in
            guard !draft.boxes.isEmpty else { throw .noBoxes }
            return Template(name: draft.name, kind: kind,
                            boxes: draft.boxes.map { Box(frame: NormalizedRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height),
                                                         content: $0.kind == .image ? .image : .text(TextBoxStyle())) })
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

    private func flow(_ s: Setup, backend: TemplateGenerationBackend = backend) -> TemplateGenerationFlow {
        let flow = TemplateGenerationFlow(app: s.app, document: s.document,
                                          editor: TemplateEditorModel(document: s.document), backend: backend)
        flow.description = "Big picture across the top"
        return flow
    }

    @Test func success_addsTemplate_undoRemovesIt_recordsTemplateLedgerLine() async throws {
        let usage = TokenUsage(inputTextTokens: 500, outputTextTokens: 300)
        let provider = FakeLayoutProvider(.success(LayoutResult(draft: Self.draft, usage: usage,
                                                                parametersSent: ["model": "gpt-6-luna"])))
        let s = try await setup(provider)
        defer { s.h.tearDown() }
        let flow = flow(s)
        let before = s.document.content.templates.count

        s.undo.beginUndoGrouping()
        await flow.generate(confirmed: true)
        s.undo.endUndoGrouping()

        guard case let .finished(id) = flow.state else { Issue.record("state \(flow.state)"); return }
        #expect(s.document.content.templates[id]?.name == "Top picture")
        #expect(s.document.content.templates.count == before + 1)
        #expect(flow.sent?.parametersSent["model"] == "gpt-6-luna")
        #expect(flow.sent?.user == "Big picture across the top")

        let records = await s.app.openBooks.costRecords(for: s.entry.id)
        let record = try #require(records.first)
        #expect(records.count == 1)
        #expect(record.kind == .template)
        #expect(record.status == .completed)
        #expect(record.model == "gpt-6-luna")
        #expect(record.estimated == Decimal(string: "0.01"))
        let expected = s.app.prices.calculator.actualCost(of: usage, provider: .openai, model: "gpt-6-luna")
        #expect(record.actual == expected)
        #expect(record.basis == (expected == nil ? .estimate : .actual))

        s.undo.undo()
        #expect(s.document.content.templates[id] == nil)
    }

    @Test func refusal_surfacesAdvice_keepsWhatWasSent_recordsFreeLine() async throws {
        let provider = FakeLayoutProvider(.failure(.refused(stage: .output, categories: [], nil)))
        let s = try await setup(provider)
        defer { s.h.tearDown() }
        let flow = flow(s)
        let before = s.document.content.templates.count

        await flow.generate(confirmed: true)

        guard case let .failed(advice) = flow.state else { Issue.record("state \(flow.state)"); return }
        #expect(!advice.headline.isEmpty)
        #expect(flow.sent?.system == "system")
        #expect(s.document.content.templates.count == before)
        let records = await s.app.openBooks.costRecords(for: s.entry.id)
        let record = try #require(records.first)
        #expect(record.kind == .template)
        #expect(record.status == .failed)
        #expect(record.actual == 0)
        #expect(record.basis == .actual)
    }

    @Test func noBoxes_failsWithoutAddingATemplate_butStillBills() async throws {
        let provider = FakeLayoutProvider(.success(LayoutResult(draft: TemplateDraft(name: "Empty", boxes: []))))
        let s = try await setup(provider)
        defer { s.h.tearDown() }
        let flow = flow(s)
        let before = s.document.content.templates.count

        await flow.generate(confirmed: true)

        guard case .failed = flow.state else { Issue.record("state \(flow.state)"); return }
        #expect(s.document.content.templates.count == before)
        let records = await s.app.openBooks.costRecords(for: s.entry.id)
        #expect(records.map(\.status) == [.completed])
    }

    @Test func noProvider_failsWithoutALedgerLine() async throws {
        let s = try await setup(nil)
        defer { s.h.tearDown() }
        let flow = flow(s)
        await flow.generate(confirmed: true)
        guard case .failed = flow.state else { Issue.record("state \(flow.state)"); return }
        #expect(await s.app.openBooks.costRecords(for: s.entry.id).isEmpty)
    }

    @Test func missingKey_isAdvice_withNoLedgerLine() async throws {
        let s = try await setup(FakeLayoutProvider(.failure(.missingKey)))
        defer { s.h.tearDown() }
        let flow = flow(s)
        await flow.generate(confirmed: true)
        guard case .failed = flow.state else { Issue.record("state \(flow.state)"); return }
        #expect(await s.app.openBooks.costRecords(for: s.entry.id).isEmpty)
        #expect(flow.sent != nil)
    }

    @Test func aboveThreshold_asksBeforeSending() async throws {
        let provider = FakeLayoutProvider(.success(LayoutResult(draft: Self.draft)))
        let s = try await setup(provider)
        defer { s.h.tearDown() }
        s.app.preferences.confirmThreshold = 0
        let flow = flow(s)

        await flow.generate()
        guard case .confirming = flow.state else { Issue.record("state \(flow.state)"); return }
        #expect(await provider.requests.isEmpty)

        s.undo.beginUndoGrouping()
        await flow.generate(confirmed: true)
        s.undo.endUndoGrouping()
        guard case .finished = flow.state else { Issue.record("state \(flow.state)"); return }
        #expect(await provider.requests.count == 1)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["BOOKBOOK_PHASE12_BBAI"] == "1"))
    func realBackend_buildsRequestAndTemplate() async throws {
        let provider = FakeLayoutProvider(.success(LayoutResult(draft: Self.draft)))
        let s = try await setup(provider)
        defer { s.h.tearDown() }
        let flow = flow(s, backend: .live)
        flow.kind = .spread
        #expect(flow.request() != nil)
        #expect(flow.estimate()?.amount != nil)
        s.undo.beginUndoGrouping()
        await flow.generate(confirmed: true)
        s.undo.endUndoGrouping()
        guard case let .finished(id) = flow.state else { Issue.record("state \(flow.state)"); return }
        #expect(s.document.content.templates[id]?.kind == .spread)
    }
}
