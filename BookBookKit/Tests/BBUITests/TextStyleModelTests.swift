import BBAI
import BBAICore
import BBModel
import BBStore
import Foundation
import Testing
@testable import BBUI

private actor FakeTextStyleProvider: TextStyleProvider {
    nonisolated var id: ProviderID { .openai }
    private var outcomes: [Result<TextStyleResult, ProviderError>]
    private(set) var requests: [TextStyleRequest] = []

    init(_ outcomes: Result<TextStyleResult, ProviderError>...) { self.outcomes = outcomes }

    func styleText(_ request: TextStyleRequest) async throws(ProviderError) -> TextStyleResult {
        requests.append(request)
        let outcome = outcomes.count > 1 ? outcomes.removeFirst() : outcomes[0]
        return try outcome.get()
    }
}

/// AI text styling's two steps (A §7.13): the design call, then the decoration queued into the
/// text box's styling session, or a typography-only version made at once.
@MainActor
struct TextStyleModelTests {
    private static let backend = TextStyleBackend(
        buildRequest: { instruction, _, _, _, _, history, _, fonts, model in
            TextStyleRequest(model: model, system: "system",
                             user: (history + [instruction]).joined(separator: " | ") + " fonts:\(fonts.count)")
        },
        estimate: { _, _ in CostEstimate(amount: 0.001, priceListAsOf: "test") },
        normalize: { draft, _, _ in
            (TextStyling(fontSize: draft.fontSize, insetFraction: draft.textInset), draft.decoration, draft.summary)
        })

    private struct Setup {
        var h: Phase9Harness
        var app: AppModel
        var document: BookDocument
        var key: TextBoxKey
    }

    private func setup(_ provider: (any TextStyleProvider)?) async throws -> Setup {
        let h = try Phase9Harness()
        var catalog = try ModelCatalog.bundled()
        if catalog.textModel(provider: .openai, id: "gpt-6-luna") == nil {
            catalog.textModels.append(CatalogTextModel(provider: .openai, id: "gpt-6-luna", displayName: "GPT-6 Luna",
                                                       kind: .text))
        }
        let app = AppModel(providers: [:], catalog: catalog, libraryRoot: h.libraryRoot,
                           keychainService: "app.bookbook.tests-\(UUID())",
                           indexCacheURL: h.dir.appending(path: "library-index.json"), userDefaults: h.defaults,
                           thumbnails: ThumbnailCache(root: h.dir.appending(path: "Caches")), appSupport: h.appSupport)
        app.textStyleProvider = provider
        app.pauseQueue()
        let entry = try h.createBook()
        let document = try await app.openBook(entry.id)
        let page = try #require(document.content.book.pageOrder.first)
        let template = try #require(document.content.pages[page].flatMap(document.content.template(for:)))
        let box = try #require(template.textBoxes.first?.id)
        return Setup(h: h, app: app, document: document, key: TextBoxKey(page: page, box: box))
    }

    private func draft(decoration: String?) -> TextStyleDraft {
        TextStyleDraft(fontSize: 28, textInset: 0.12, decoration: decoration, summary: "A leafy frame.")
    }

    @Test func design_thenQueuesTheDecorationWithTheStyle() async throws {
        let provider = FakeTextStyleProvider(.success(TextStyleResult(
            draft: draft(decoration: "green leaves around the edge"), usage: TokenUsage(inputTextTokens: 300),
            parametersSent: ["model": "gpt-6-luna"])))
        let s = try await setup(provider)
        defer { s.h.tearDown() }
        let model = TextStyleModel(document: s.document, backend: Self.backend)

        await model.run("leafy frame", quality: .draft, refines: nil, for: s.key, app: s.app)

        #expect(model.state(for: s.key) == .idle)
        let slot = try #require(s.document.content.pages[s.key.page]?.textStyles[s.key.box])
        let session = try #require(s.document.content.sessions[slot.sessionID])
        #expect(session.owner == .textBox(s.key.page, s.key.box))
        let message = try #require(session.messages.last)
        #expect(message.text == "leafy frame")
        let itemID = try #require(message.queueItemID)
        let item = try #require(await s.app.queue.snapshot().entry(for: itemID)?.item)
        #expect(item.target == .textBox(s.key.page, s.key.box))
        #expect(item.intent.checkConsistency == false)
        #expect(item.intent.includeStoryText == false)
        let style = try #require(item.intent.textStyle)
        #expect(style.decorationPrompt == "green leaves around the edge")
        #expect(style.styling.fontSize == 28)
        #expect(style.call.user.hasPrefix("leafy frame"))
        #expect(style.call.parametersSent == ["model": "gpt-6-luna"])
        #expect(style.call.cost != nil)
        #expect(item.display.boxLabel == "Text Style")
        // Nothing is shown until the decoration arrives.
        #expect(slot.versionID == nil)
        #expect(await provider.requests.count == 1)
    }

    @Test func typographyOnly_makesTheVersionAtOnce() async throws {
        let s = try await setup(FakeTextStyleProvider(.success(TextStyleResult(draft: draft(decoration: nil)))))
        defer { s.h.tearDown() }
        let model = TextStyleModel(document: s.document, backend: Self.backend)

        await model.run("bigger text", quality: .draft, refines: nil, for: s.key, app: s.app)

        #expect(model.state(for: s.key) == .idle)
        let applied = try #require(s.document.content.appliedTextStyle(page: s.key.page, box: s.key.box))
        #expect(applied.decoration == nil)
        #expect(applied.styling.fontSize == 28)
        #expect(applied.version.textStyle?.summary == "A leafy frame.")
        #expect(await s.app.queue.snapshot().entries.isEmpty)

        // A follow-up sends the thread so far.
        await model.run("now red", quality: .draft, refines: applied.version.id, for: s.key, app: s.app)
        let sessionID = try #require(s.document.content.pages[s.key.page]?.textStyles[s.key.box]?.sessionID)
        let session = try #require(s.document.content.sessions[sessionID])
        #expect(session.versions.count == 2)
        #expect(session.versions.last?.parent == applied.version.id)
    }

    @Test func refusal_showsAdviceAndQueuesNothing() async throws {
        let s = try await setup(FakeTextStyleProvider(.failure(.refused(stage: .output, categories: [], nil))))
        defer { s.h.tearDown() }
        let model = TextStyleModel(document: s.document, backend: Self.backend)

        await model.run("something", quality: .draft, refines: nil, for: s.key, app: s.app)

        guard case let .failed(instruction, _, sent) = model.state(for: s.key) else {
            Issue.record("expected a failure")
            return
        }
        #expect(instruction == "something")
        #expect(sent?.user.hasPrefix("something") == true)
        #expect(s.document.content.pages[s.key.page]?.textStyles[s.key.box] == nil)
        #expect(await s.app.queue.snapshot().entries.isEmpty)
        model.dismissFailure(s.key)
        #expect(model.state(for: s.key) == .idle)
    }

    @Test func noProvider_failsWithoutCalling() async throws {
        let s = try await setup(nil)
        defer { s.h.tearDown() }
        let model = TextStyleModel(document: s.document, backend: Self.backend)
        await model.run("something", quality: .draft, refines: nil, for: s.key, app: s.app)
        guard case let .failed(_, advice, sent) = model.state(for: s.key) else {
            Issue.record("expected a failure")
            return
        }
        #expect(advice.headline == "AI text styling isn't available")
        #expect(sent == nil)
    }

    @Test func estimate_includesTheDesignAndTheDecoration() async throws {
        let s = try await setup(FakeTextStyleProvider(.success(TextStyleResult(draft: draft(decoration: nil)))))
        defer { s.h.tearDown() }
        let model = TextStyleModel(document: s.document, backend: Self.backend)
        let estimate = model.estimate("gold frame", quality: .draft, refines: nil, for: s.key, app: s.app)
        let decoration = s.app.ownEstimate(model.decorationIntent("gold frame", quality: .draft, refines: nil,
                                                                  app: s.app),
                                           target: .textBox(s.key.page, s.key.box), content: s.document.content)
        #expect(estimate == CostEstimate.total([CostEstimate(amount: 0.001, priceListAsOf: "test"), decoration]))
    }
}
