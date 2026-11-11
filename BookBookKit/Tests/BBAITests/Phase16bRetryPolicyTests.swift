import BBAICore
import BBModel
import Foundation
import Testing
@testable import BBAI

@Suite struct Phase16bRetryPolicyTests {
    @Test func offlineWritesNoLedgerLine() {
        #expect(QueueLedgerRule.forFailure(.offline) == .none)
    }

    @Test func timeoutStillEstimates() {
        #expect(QueueLedgerRule.forFailure(.timeout) == .estimate(.failed))
    }

    @Test func completedChargePricesUsageElseEstimates() {
        let pricing = FakePricing()
        let usage = TokenUsage(inputTextTokens: 10)
        #expect(LedgerCharge.completed(usage: usage, provider: .openai, model: "gpt-image-2.5-sunburst", pricing: pricing)
            == LedgerCharge(status: .completed, basis: .actual, actual: Decimal(string: "0.012")!))
        // No usage, or no price entry: the estimate.
        #expect(LedgerCharge.completed(usage: nil, provider: .openai, model: "gpt-image-2.5-sunburst", pricing: pricing)
            == LedgerCharge(status: .completed, basis: .estimate, actual: nil))
        #expect(LedgerCharge.completed(usage: usage, provider: .openai, model: "unpriced", pricing: pricing)
            == LedgerCharge(status: .completed, basis: .estimate, actual: nil))
    }
}
