import BBModel
import Foundation
import Testing
@testable import BBAI

@Suite struct CostPolicyTests {
    private func decide(_ amount: Decimal?, threshold: Decimal = 0.50, total: Decimal = 0, budget: Decimal? = nil) -> CostDecision {
        CostPolicy.decide(estimate: CostEstimate(amount: amount), threshold: threshold, bookTotal: total, budget: budget)
    }

    @Test func defaultThresholdIsFiftyCents() {
        #expect(CostPolicy.defaultThreshold == 0.50)
    }

    @Test func confirmsOnlyAboveThreshold() {
        #expect(decide(0.49).needsConfirmation == false)
        #expect(decide(0.50).needsConfirmation == false)
        #expect(decide(0.51).needsConfirmation == true)
    }

    @Test func unknownAmountNeedsConfirmation() {
        #expect(CostPolicy.decide(estimate: .unknown, threshold: 0.5, bookTotal: 0, budget: nil).needsConfirmation)
    }

    @Test func budgetEdge() {
        #expect(decide(0.01, total: 5, budget: 5).overBudget == false)
        #expect(decide(0.01, total: 5.01, budget: 5).overBudget == true)
        #expect(decide(0.01, total: 500, budget: nil).overBudget == false)
    }

    @Test func zeroThresholdConfirmsEverythingPositive() {
        #expect(decide(0.001, threshold: 0).needsConfirmation)
        #expect(decide(0, threshold: 0).needsConfirmation == false)
    }
}
