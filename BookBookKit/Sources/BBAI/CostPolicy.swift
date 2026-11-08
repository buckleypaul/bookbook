import Foundation

/// Decides, before enqueueing, whether to ask for confirmation and whether to warn about the
/// book's budget (A §7.10 "Policies"). The budget warning never blocks.
public enum CostPolicy {
    /// The Settings default: confirm anything above $0.50.
    public static let defaultThreshold: Decimal = 0.50

    public static func decide(estimate: CostEstimate, threshold: Decimal, bookTotal: Decimal,
                              budget: Decimal?) -> CostDecision {
        let needsConfirmation = estimate.amount.map { $0 > threshold } ?? true
        let overBudget = budget.map { bookTotal > $0 } ?? false
        return CostDecision(needsConfirmation: needsConfirmation, overBudget: overBudget)
    }
}
