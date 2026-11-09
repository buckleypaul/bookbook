import BBAI
import BBAICore
import BBModel
import BBStore
import Foundation
import Observation

// Phase 12 lane L5: "Generate layout with AI" (PD §8.4, A §7.7, §7.10, §7.11). Template requests
// run directly, outside the generation queue, with progress shown in the sheet.

/// The BBAI pieces a template request needs, injectable so the flow is testable independent of
/// the prompt, normalizer and estimator implementations.
public struct TemplateGenerationBackend: Sendable {
    public var buildRequest: @Sendable (_ description: String, _ kind: TemplateKind, _ pageSetup: PageSetup,
                                        _ presets: [Template], _ model: CatalogTextModel) -> LayoutRequest
    public var estimate: @Sendable (_ request: LayoutRequest, _ priceList: PriceList) -> CostEstimate
    public var normalize: @Sendable (_ draft: TemplateDraft, _ kind: TemplateKind,
                                     _ pageSetup: PageSetup) throws(TemplateDraftError) -> Template

    public init(
        buildRequest: @escaping @Sendable (String, TemplateKind, PageSetup, [Template], CatalogTextModel) -> LayoutRequest,
        estimate: @escaping @Sendable (LayoutRequest, PriceList) -> CostEstimate,
        normalize: @escaping @Sendable (TemplateDraft, TemplateKind, PageSetup) throws(TemplateDraftError) -> Template
    ) {
        self.buildRequest = buildRequest
        self.estimate = estimate
        self.normalize = normalize
    }

    /// `LayoutPrompt`, `CostEstimator` and `TemplateNormalizer`.
    public static let live = TemplateGenerationBackend(
        buildRequest: { LayoutPrompt.request(description: $0, kind: $1, pageSetup: $2, presets: $3, model: $4) },
        estimate: { CostEstimator.estimate(layout: $0, priceList: $1) },
        normalize: { draft, kind, setup throws(TemplateDraftError) in
            try TemplateNormalizer.template(from: draft, kind: kind, pageSetup: setup)
        })
}

/// What a template request sent (A §11): shown under "What was sent", after success or failure.
public struct TemplateSentRecord: Hashable, Sendable {
    public var model: String
    public var system: String
    public var user: String
    public var parametersSent: [String: String]
}

public enum TemplateGenerationState: Hashable, Sendable {
    case idle
    /// The estimate is above the Settings threshold (or the book is over budget): waiting for the user.
    case confirming(CostEstimate, overBudget: Bool)
    case running
    case failed(FailureAdvice)
    /// The template was added to the book.
    case finished(TemplateID)
}

/// One run of the AI layout sheet. The view only renders this state.
@MainActor @Observable
public final class TemplateGenerationFlow {
    public var description = ""
    /// `.single` or `.spread`.
    public var kind: TemplateKind = .single
    public private(set) var state: TemplateGenerationState = .idle
    public private(set) var sent: TemplateSentRecord?

    @ObservationIgnored private let app: AppModel
    @ObservationIgnored private let document: BookDocument
    @ObservationIgnored private let editor: TemplateEditorModel?
    @ObservationIgnored private let backend: TemplateGenerationBackend

    public init(app: AppModel, document: BookDocument, editor: TemplateEditorModel? = nil,
                backend: TemplateGenerationBackend = .live) {
        self.app = app
        self.document = document
        self.editor = editor
        self.backend = backend
    }

    public var trimmedDescription: String { description.trimmingCharacters(in: .whitespacesAndNewlines) }

    public var isRunning: Bool { state == .running }

    /// The Settings default template model, when the catalog has it.
    public var model: CatalogTextModel? {
        app.catalog.textModel(provider: app.layoutProvider?.id ?? .openai, id: app.preferences.defaultTemplateModelID)
    }

    /// The rendered request for the current description, nil without a description or model.
    public func request() -> LayoutRequest? {
        guard !trimmedDescription.isEmpty, let model else { return nil }
        return backend.buildRequest(trimmedDescription, kind, document.content.style.pageSetup,
                                    Presets.bundledTemplates, model)
    }

    /// The estimate shown before sending; nil when there is nothing to send yet.
    public func estimate() -> CostEstimate? {
        request().map { backend.estimate($0, app.prices.current) }
    }

    /// Starts a request. Above the confirm threshold this stops at `.confirming` first.
    public func generate(confirmed: Bool = false) async {
        guard !isRunning else { return }
        guard let provider = app.layoutProvider else {
            return fail(FailureAdvice(headline: "AI layouts aren't available",
                                      explanation: "No provider is set up for layout requests. Add your API key in Settings."))
        }
        guard let model else {
            return fail(FailureAdvice(
                headline: "The layout model isn't available",
                explanation: "“\(app.preferences.defaultTemplateModelID)” isn't in the model list. Choose another layout model in Settings."))
        }
        guard let request = request() else { return }
        let estimate = backend.estimate(request, app.prices.current)
        if !confirmed {
            let decision = await app.costDecision(for: estimate, in: document)
            if decision.needsConfirmation || decision.overBudget {
                state = .confirming(estimate, overBudget: decision.overBudget)
                return
            }
        }
        state = .running
        sent = nil
        do throws(ProviderError) {
            let result = try await provider.generateLayout(request)
            sent = Self.record(request, parametersSent: result.parametersSent)
            await recordCost(model: model, provider: provider.id, estimate: estimate, usage: result.usage)
            finish(result.draft)
        } catch {
            sent = Self.record(request, parametersSent: [:])
            if let rule = Self.ledgerRule(for: error) {
                await recordCost(model: model, provider: provider.id, estimate: estimate, usage: nil, failure: rule)
            }
            if error == .cancelled {
                state = .idle
            } else {
                fail(RefusalAdvisor.advise(error, context: AdviceContext(provider: provider.id, report: nil)))
            }
        }
    }

    public func cancelConfirmation() {
        if case .confirming = state { state = .idle }
    }

    /// Back to the form after a failure (keeps the description and what was sent).
    public func reset() {
        if !isRunning { state = .idle }
    }

    // MARK: Private

    private func finish(_ draft: TemplateDraft) {
        let template: Template
        do throws(TemplateDraftError) {
            template = try backend.normalize(draft, kind, document.content.style.pageSetup)
        } catch {
            return fail(FailureAdvice(
                headline: "The layout had no usable boxes",
                explanation: "The model's answer didn't contain any picture or text areas that fit the page.",
                fixes: ["Describe where the picture and the text go, for example “picture across the top, text below”."]))
        }
        guard document.perform(.addTemplate(template)) else {
            return fail(FailureAdvice(headline: "Couldn't add the layout",
                                      explanation: "The book can't be edited right now."))
        }
        editor?.open(template.id)
        state = .finished(template.id)
    }

    private func fail(_ advice: FailureAdvice) {
        state = .failed(advice)
    }

    private static func record(_ request: LayoutRequest, parametersSent: [String: String]) -> TemplateSentRecord {
        TemplateSentRecord(model: request.model.id, system: request.system, user: request.user,
                           parametersSent: parametersSent)
    }

    /// A §7.10: error responses are free; unknown outcomes (cancelled, timeout, transport) are the
    /// estimate; a request that never left (no key) has no line. Mirrors the queue's rule.
    private enum Failure { case free, estimate(CostStatus) }

    private static func ledgerRule(for error: ProviderError) -> Failure? {
        switch error {
        case .missingKey: nil
        case .cancelled: .estimate(.cancelled)
        case .timeout, .offline: .estimate(.failed)
        case .invalidKey, .verificationRequired, .regionUnsupported, .billing, .rateLimited, .refused,
             .invalidRequest, .modelUnavailable: .free
        case let .transient(raw), let .noImage(raw), let .unknown(raw):
            (raw?.status).map { $0 >= 400 } == true ? .free : .estimate(.failed)
        }
    }

    private func recordCost(model: CatalogTextModel, provider: ProviderID, estimate: CostEstimate,
                            usage: TokenUsage?, failure: Failure? = nil) async {
        let status: CostStatus, basis: CostBasis, actual: Decimal?
        switch failure {
        case nil:
            status = .completed
            actual = usage.flatMap { app.prices.calculator.actualCost(of: $0, provider: provider, model: model.id) }
            basis = actual == nil ? .estimate : .actual
        case .free?:
            (status, basis, actual) = (.failed, .actual, 0)
        case let .estimate(s)?:
            (status, basis, actual) = (s, .estimate, nil)
        }
        let list = app.prices.current
        let record = CostRecord(at: app.now(), kind: .template, provider: provider, model: model.id, quality: nil,
                                target: nil, status: status, estimated: estimate.amount ?? 0, actual: actual,
                                basis: basis,
                                priceListAsOf: basis == .actual ? list.asOf : (estimate.priceListAsOf ?? list.asOf))
        await app.openBooks.recordCost(record, in: document.id)
    }
}
