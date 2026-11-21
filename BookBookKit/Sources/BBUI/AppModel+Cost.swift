import BBAI
import BBAICore
import BBModel
import BBStore
import Foundation

// The cost estimate decisions, the ledger and the budget (A §7.10).

extension AppModel {
    /// Asks `CostPolicy` with the Settings threshold and the book's ledger total and budget.
    public func costDecision(for estimate: CostEstimate, in document: BookDocument) async -> CostDecision {
        await costDecisionAndSpent(for: estimate, in: document).decision
    }

    /// `costDecision` plus the book's ledger total it was decided on (for the alert text),
    /// from one read of the ledger.
    public func costDecisionAndSpent(for estimate: CostEstimate,
                                     in document: BookDocument) async -> (decision: CostDecision, spent: Decimal) {
        let total = await ledgerSummary(for: document.id).total
        let decision = CostPolicy.decide(estimate: estimate, threshold: preferences.confirmThreshold,
                                         bookTotal: total, budget: document.content.book.budget)
        return (decision, total)
    }

    /// The book's ledger totals (Book Settings → Cost, PD §8.12). Read off the main actor.
    public func ledgerSummary(for bookID: BookID) async -> LedgerSummary {
        let read = await openBooks.costLedgerRead(for: bookID)
        return LedgerSummary(records: read.records, skippedLines: read.skipped)
    }

    /// The ledger line for `Provenance.cost` (Version details).
    public func costRecord(_ id: CostRecordID, in bookID: BookID) async -> CostRecord? {
        await openBooks.costRecords(for: bookID).last { $0.id == id }
    }

    /// The ledger lines for several `CostRecordID`s from one read (nil stays nil, as does a missing line).
    func costRecords(_ ids: [CostRecordID?], in bookID: BookID) async -> [CostRecord?] {
        guard ids.contains(where: { $0 != nil }) else { return ids.map { _ in nil } }
        let records = await openBooks.costRecords(for: bookID)
        return ids.map { id in id.flatMap { id in records.last { $0.id == id } } }
    }

    /// Not undoable (like the author). nil clears the budget.
    @discardableResult
    public func setBudget(_ budget: Decimal?, in document: BookDocument) -> Bool {
        document.setBudget(budget)
    }

    // MARK: Text-model requests (the Layouts chat and text styling run outside the queue)

    /// The Settings layout model (text styling uses the same one) in `provider`'s part of the
    /// catalog (nil = OpenAI), when the catalog has it.
    func defaultTextModel(for provider: ProviderID?) -> CatalogTextModel? {
        catalog.textModel(provider: provider ?? .openai, id: preferences.defaultTemplateModelID)
    }

    /// What a request says when `defaultTextModel` is nil.
    var missingTextModelAdvice: String {
        "“\(preferences.defaultTemplateModelID)” isn't in the model list. Choose another layout model in Settings."
    }

    /// Writes the ledger line for a text-model request into the book; returns the line's ID.
    @discardableResult
    func recordTextModelCost(kind: CostKind, model: CatalogTextModel, provider: ProviderID, target: GenerationTarget?,
                             estimate: CostEstimate, charge: LedgerCharge, in bookID: BookID) async -> CostRecordID {
        let record = CostRecord(at: now(), kind: kind, provider: provider, model: model.id, quality: nil,
                                target: target, charge: charge, estimate: estimate,
                                currentPriceListAsOf: prices.current.asOf)
        await openBooks.recordCost(record, in: bookID)
        return record.id
    }

    /// The ledger line for a text-model request that failed with `error`, by the queue's rule
    /// (A §7.10), so it is billed like an image request. Nil means no line: nothing left the
    /// machine (no key, offline).
    func recordTextModelFailure(_ error: ProviderError, kind: CostKind, model: CatalogTextModel, provider: ProviderID,
                                target: GenerationTarget?, estimate: CostEstimate,
                                in bookID: BookID) async -> CostRecordID? {
        guard let charge = QueueLedgerRule.forFailure(error).charge else { return nil }
        return await recordTextModelCost(kind: kind, model: model, provider: provider, target: target,
                                         estimate: estimate, charge: charge, in: bookID)
    }
}
