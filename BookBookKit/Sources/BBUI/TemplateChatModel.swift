import BBAI
import BBAICore
import BBModel
import BBStore
import Foundation
import Observation

// The Layouts chat (PD §8.4, A §7.7, §7.10, §7.11): the Layouts tab's trailing panel is a chat
// thread per template. The first message designs an empty template; later ones revise it. Each
// reply replaces the template as one undo step. Requests run directly, outside the generation
// queue; threads live in memory for the window's lifetime.

/// The BBAI pieces a layout request needs, injectable so the chat is testable independent of
/// the prompt, normalizer and estimator implementations.
public struct TemplateChatBackend: Sendable {
    /// A design request for an empty template.
    public var buildRequest: @Sendable (_ description: String, _ kind: TemplateKind, _ pageSetup: PageSetup,
                                        _ presets: [Template], _ model: CatalogTextModel) -> LayoutRequest
    /// A revision request: instruction, earlier instructions (oldest first), the current template.
    public var buildRevision: @Sendable (_ instruction: String, _ history: [String], _ current: Template,
                                         _ pageSetup: PageSetup, _ model: CatalogTextModel) -> LayoutRequest
    public var estimate: @Sendable (_ request: LayoutRequest, _ priceList: PriceList) -> CostEstimate
    /// The draft applied to the current template (box IDs kept where they match).
    public var revise: @Sendable (_ current: Template, _ draft: TemplateDraft,
                                  _ pageSetup: PageSetup) throws(TemplateDraftError) -> Template

    public init(
        buildRequest: @escaping @Sendable (String, TemplateKind, PageSetup, [Template], CatalogTextModel) -> LayoutRequest,
        buildRevision: @escaping @Sendable (String, [String], Template, PageSetup, CatalogTextModel) -> LayoutRequest,
        estimate: @escaping @Sendable (LayoutRequest, PriceList) -> CostEstimate,
        revise: @escaping @Sendable (Template, TemplateDraft, PageSetup) throws(TemplateDraftError) -> Template
    ) {
        self.buildRequest = buildRequest
        self.buildRevision = buildRevision
        self.estimate = estimate
        self.revise = revise
    }

    /// `LayoutPrompt`, `CostEstimator` and `TemplateNormalizer`.
    public static let live = TemplateChatBackend(
        buildRequest: { LayoutPrompt.request(description: $0, kind: $1, pageSetup: $2, presets: $3, model: $4) },
        buildRevision: { LayoutPrompt.revisionRequest(instruction: $0, history: $1, current: $2, pageSetup: $3, model: $4) },
        estimate: { CostEstimator.estimate(layout: $0, priceList: $1) },
        revise: { current, draft, setup throws(TemplateDraftError) in
            try TemplateNormalizer.revise(current, with: draft, pageSetup: setup)
        })
}

/// What a layout request sent (A §11): shown under "What was sent", after success or failure.
public struct TemplateSentRecord: Hashable, Sendable {
    public var model: String
    public var system: String
    public var user: String
    public var parametersSent: [String: String]
}

/// One entry of a template's chat thread.
public struct TemplateChatMessage: Identifiable, Hashable, Sendable {
    public enum Role: Hashable, Sendable { case user, assistant }

    public let id: UUID
    public var role: Role
    /// The user's instruction, or the reply's summary.
    public var text: String
    /// Replies that changed the template: the template right after the change ("Restore This").
    public var snapshot: Template?
    /// Replies that failed: what went wrong and what to try.
    public var failure: FailureAdvice?
    /// Replies: what was sent, when anything left the machine.
    public var sent: TemplateSentRecord?
    /// Failed replies: the instruction "Try Again" re-sends.
    public var retryInstruction: String?

    init(role: Role, text: String, snapshot: Template? = nil, failure: FailureAdvice? = nil,
         sent: TemplateSentRecord? = nil, retryInstruction: String? = nil) {
        self.id = UUID()
        self.role = role
        self.text = text
        self.snapshot = snapshot
        self.failure = failure
        self.sent = sent
        self.retryInstruction = retryInstruction
    }
}

public enum TemplateChatState: Hashable, Sendable {
    case idle
    /// The estimate is above the Settings threshold (or the book is over budget): waiting for the user.
    case confirming(CostEstimate, overBudget: Bool, instruction: String, isRetry: Bool)
    case running
}

/// The Layouts tab's chat threads (one per template, in memory) and the trailing panel's pane.
/// The view only renders this state.
@MainActor @Observable
public final class TemplateChatModel {
    /// The Layouts tab's trailing panel: the chat, or the box inspector.
    public enum Pane: Hashable, Sendable { case chat, box }

    public var pane: Pane = .chat
    public private(set) var threads: [TemplateID: [TemplateChatMessage]] = [:]
    public private(set) var states: [TemplateID: TemplateChatState] = [:]
    /// Templates with a send in progress, claimed synchronously so a double Send can't start two.
    private var busy: Set<TemplateID> = []
    /// Unsent composer text per template.
    public var drafts: [TemplateID: String] = [:]
    /// Set by "New with AI"; the composer takes focus and clears it.
    public var wantsComposerFocus = false

    @ObservationIgnored private let document: BookDocument
    @ObservationIgnored private let editor: TemplateEditorModel
    @ObservationIgnored private let backend: TemplateChatBackend
    @ObservationIgnored private var tasks: [TemplateID: Task<Void, Never>] = [:]

    public init(document: BookDocument, editor: TemplateEditorModel, backend: TemplateChatBackend = .live) {
        self.document = document
        self.editor = editor
        self.backend = backend
    }

    public func messages(for id: TemplateID) -> [TemplateChatMessage] { threads[id] ?? [] }

    public func state(for id: TemplateID) -> TemplateChatState { states[id] ?? .idle }

    /// True from Send until the reply is in (including the cost check before `.running`).
    public func isRunning(_ id: TemplateID) -> Bool { busy.contains(id) || state(for: id) == .running }

    /// "New with AI": a blank template of `kind`, opened, with the chat focused. The first
    /// message designs it.
    public func newTemplateWithAI(kind: TemplateKind) {
        editor.newTemplate(kind: kind)
        pane = .chat
        wantsComposerFocus = true
    }

    /// The Settings default layout model, when the catalog has it.
    public func model(_ app: AppModel) -> CatalogTextModel? {
        app.catalog.textModel(provider: app.layoutProvider?.id ?? .openai, id: app.preferences.defaultTemplateModelID)
    }

    /// The rendered request for `instruction` against the template as it is now; nil without
    /// an instruction, a model or the template. An empty template gets a design request.
    public func request(_ instruction: String, for id: TemplateID, app: AppModel,
                        isRetry: Bool = false) -> LayoutRequest? {
        let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let model = model(app), let template = Presets.template(id, in: document.content)
        else { return nil }
        let setup = document.content.style.pageSetup
        if template.boxes.isEmpty {
            return backend.buildRequest(text, template.kind, setup, Presets.bundledTemplates, model)
        }
        var earlier = history(id)
        // Try Again: the failed instruction is already the thread's last one.
        if isRetry, earlier.last == text { earlier.removeLast() }
        return backend.buildRevision(text, earlier, template, setup, model)
    }

    /// The estimate shown in the composer; nil when there is nothing to send yet.
    public func estimate(_ instruction: String, for id: TemplateID, app: AppModel) -> CostEstimate? {
        request(instruction, for: id, app: app).map { backend.estimate($0, app.prices.current) }
    }

    /// Starts `send` in a task the model owns (so Stop can cancel it).
    public func submit(_ instruction: String, to id: TemplateID, app: AppModel, confirmed: Bool = false,
                       isRetry: Bool = false) {
        guard !isRunning(id) else { return }
        busy.insert(id)
        tasks[id] = Task { [weak self] in
            await self?.perform(instruction, to: id, app: app, confirmed: confirmed, isRetry: isRetry)
            self?.tasks[id] = nil
        }
    }

    /// Sends `instruction` about template `id`. Above the confirm threshold this stops at
    /// `.confirming` first (nothing is added to the thread until it's sent). `isRetry` re-sends
    /// a failed instruction without repeating it in the thread.
    public func send(_ instruction: String, to id: TemplateID, app: AppModel, confirmed: Bool = false,
                     isRetry: Bool = false) async {
        guard !isRunning(id) else { return }
        busy.insert(id)
        await perform(instruction, to: id, app: app, confirmed: confirmed, isRetry: isRetry)
    }

    /// `send` after the template's slot is claimed; releases it when done.
    private func perform(_ instruction: String, to id: TemplateID, app: AppModel, confirmed: Bool,
                         isRetry: Bool) async {
        defer { busy.remove(id) }
        let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, Presets.template(id, in: document.content) != nil else { return }
        guard let provider = app.layoutProvider else {
            return fail(id, instruction: text, isRetry: isRetry, FailureAdvice(
                headline: "AI layouts aren't available",
                explanation: "No provider is set up for layout requests. Add your API key in Settings."))
        }
        guard let model = model(app) else {
            return fail(id, instruction: text, isRetry: isRetry, FailureAdvice(
                headline: "The layout model isn't available",
                explanation: "“\(app.preferences.defaultTemplateModelID)” isn't in the model list. Choose another layout model in Settings."))
        }
        guard let request = request(text, for: id, app: app, isRetry: isRetry) else { return }
        let estimate = backend.estimate(request, app.prices.current)
        if !confirmed {
            let decision = await app.costDecision(for: estimate, in: document)
            if decision.needsConfirmation || decision.overBudget {
                states[id] = .confirming(estimate, overBudget: decision.overBudget, instruction: text, isRetry: isRetry)
                return
            }
        }
        if !isRetry { append(id, TemplateChatMessage(role: .user, text: text)) }
        drafts[id] = nil
        states[id] = .running
        defer { states[id] = .idle }
        do throws(ProviderError) {
            let result = try await provider.generateLayout(request)
            let sent = Self.record(request, parametersSent: result.parametersSent)
            await recordCost(app, model: model, provider: provider.id, estimate: estimate, .completed(
                usage: result.usage, provider: provider.id, model: model.id, pricing: app.prices.calculator))
            apply(result.draft, to: id, instruction: text, sent: sent)
        } catch {
            // The queue's rule (A §7.10), so a layout request is billed like an image request.
            let rule = QueueLedgerRule.forFailure(error)
            // No ledger line means nothing left the machine (no key, offline): nothing to show as sent.
            let sent = rule == QueueLedgerRule.none ? nil : Self.record(request, parametersSent: [:])
            if let charge = rule.charge {
                await recordCost(app, model: model, provider: provider.id, estimate: estimate, charge)
            }
            if error == .cancelled {
                append(id, TemplateChatMessage(role: .assistant, text: "Stopped.", sent: sent, retryInstruction: text))
            } else {
                append(id, TemplateChatMessage(
                    role: .assistant, text: "",
                    failure: RefusalAdvisor.advise(error, context: AdviceContext(provider: provider.id, report: nil)),
                    sent: sent, retryInstruction: text))
            }
        }
    }

    /// Stop: cancels the running request for `id`.
    public func cancel(_ id: TemplateID) {
        tasks[id]?.cancel()
    }

    public func cancelConfirmation(_ id: TemplateID) {
        if case .confirming = state(for: id) { states[id] = .idle }
    }

    /// True when restoring `message`'s snapshot would change the template.
    public func canRestore(_ message: TemplateChatMessage, in id: TemplateID) -> Bool {
        guard let snapshot = message.snapshot, let current = Presets.template(id, in: document.content)
        else { return false }
        return snapshot.boxes != current.boxes || snapshot.name != current.name
    }

    /// "Restore This": puts the template back the way that reply left it (one undo step).
    public func restore(_ message: TemplateChatMessage, in id: TemplateID) {
        guard let snapshot = message.snapshot else { return }
        editor.update(id, actionName: "Restore Layout") { template in
            template.boxes = snapshot.boxes
            template.name = snapshot.name
        }
    }

    // MARK: Private

    /// The thread's earlier instructions (oldest first), for the revision prompt.
    private func history(_ id: TemplateID) -> [String] {
        messages(for: id).filter { $0.role == .user }.map(\.text)
    }

    private func append(_ id: TemplateID, _ message: TemplateChatMessage) {
        threads[id, default: []].append(message)
    }

    private func fail(_ id: TemplateID, instruction: String, isRetry: Bool, _ advice: FailureAdvice) {
        if !isRetry { append(id, TemplateChatMessage(role: .user, text: instruction)) }
        drafts[id] = nil
        append(id, TemplateChatMessage(role: .assistant, text: "", failure: advice, retryInstruction: instruction))
    }

    /// Applies the reply to the template as it is now (the user may have edited it meanwhile).
    private func apply(_ draft: TemplateDraft, to id: TemplateID, instruction: String, sent: TemplateSentRecord) {
        func failure(_ advice: FailureAdvice) {
            append(id, TemplateChatMessage(role: .assistant, text: "", failure: advice, sent: sent,
                                           retryInstruction: instruction))
        }
        guard let current = Presets.template(id, in: document.content) else {
            return failure(FailureAdvice(headline: "The layout is gone",
                                         explanation: "This layout was deleted before the answer arrived."))
        }
        var revised: Template
        do throws(TemplateDraftError) {
            revised = try backend.revise(current, draft, document.content.style.pageSetup)
        } catch {
            return failure(FailureAdvice(
                headline: "The layout had no usable boxes",
                explanation: "The model's answer didn't contain any picture or text areas that fit the page.",
                fixes: ["Describe where the picture and the text go, for example “picture across the top, text below”."]))
        }
        let designed = current.boxes.isEmpty
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if designed, !name.isEmpty { revised.name = name }
        guard document.isEditable else {
            return failure(FailureAdvice(headline: "Couldn't change the layout",
                                         explanation: "The book can't be edited right now."))
        }
        editor.update(id, actionName: designed ? "AI Layout" : "AI Layout Change") { $0 = revised }
        // What the book holds (an edit may adjust it, e.g. bleed dropped off a spread's fold).
        let applied = Presets.template(id, in: document.content) ?? revised
        append(id, TemplateChatMessage(role: .assistant, text: Self.summary(applied, designed: designed),
                                       snapshot: applied, sent: sent))
    }

    static func summary(_ template: Template, designed: Bool) -> String {
        let images = template.boxes.filter { if case .image = $0.content { true } else { false } }.count
        let texts = template.boxes.count - images
        var parts: [String] = []
        if images > 0 { parts.append(images == 1 ? "1 picture box" : "\(images) picture boxes") }
        if texts > 0 { parts.append(texts == 1 ? "1 text box" : "\(texts) text boxes") }
        let boxes = parts.joined(separator: " and ")
        return designed ? "Made “\(template.name)” with \(boxes)." : "Updated the layout: \(boxes)."
    }

    private static func record(_ request: LayoutRequest, parametersSent: [String: String]) -> TemplateSentRecord {
        TemplateSentRecord(model: request.model.id, system: request.system, user: request.user,
                           parametersSent: parametersSent)
    }

    private func recordCost(_ app: AppModel, model: CatalogTextModel, provider: ProviderID, estimate: CostEstimate,
                            _ charge: LedgerCharge) async {
        let record = CostRecord(at: app.now(), kind: .template, provider: provider, model: model.id, quality: nil,
                                target: nil, charge: charge, estimate: estimate,
                                currentPriceListAsOf: app.prices.current.asOf)
        await app.openBooks.recordCost(record, in: document.id)
    }
}
