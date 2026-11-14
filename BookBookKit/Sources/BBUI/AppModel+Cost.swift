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
}
