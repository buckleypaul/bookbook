import BBAI
import BBModel
import Foundation
import Testing
@testable import BBUI

@Suite struct CostTextTests {
    @Test func amountsUseTwoPlacesOrFourUnderACent() {
        #expect(CostText.amount(Decimal(string: "0.07")!) == "$0.07")
        #expect(CostText.amount(Decimal(string: "0.0059")!) == "$0.0059")
        #expect(CostText.amount(0) == "$0.00")
        #expect(CostText.amount(Decimal(string: "12.345")!) == "$12.35")
        #expect(CostText.amount(1234) == "$1234.00")
    }

    @Test func estimateTextAndUnknown() {
        #expect(CostText.estimate(CostEstimate(amount: Decimal(string: "0.0712")!)) == "about $0.07")
        #expect(CostText.estimate(.unknown) == "cost unknown")
    }

    @Test func recordLabelsActualAndEstimate() {
        func record(_ basis: CostBasis, _ amount: String) -> CostRecord {
            CostRecord(at: Date(), kind: .image, provider: .openai, model: "m", quality: .draft, target: nil,
                       status: .completed, estimated: Decimal(string: "0.0059")!,
                       actual: basis == .actual ? Decimal(string: amount) : nil, basis: basis, priceListAsOf: nil)
        }
        #expect(CostText.record(record(.estimate, "0")) == "$0.0059 (estimate)")
        #expect(CostText.record(record(.actual, "0.06")) == "$0.06 (actual)")
    }

    @Test func elapsedAgainstTypical() {
        #expect(ElapsedTimeText.progress(elapsed: 42, typical: 70) == "0:42 of ~1:10")
        #expect(ElapsedTimeText.progress(elapsed: 42, typical: nil) == "0:42")
        #expect(ElapsedTimeText.progress(elapsed: 5, typical: 0) == "0:05")
        #expect(ElapsedTimeText.progress(elapsed: -3, typical: 10) == "0:00 of ~0:10")
    }

    @Test func requestAlertCombinesThresholdAndBudget() {
        let est = CostEstimate(amount: Decimal(string: "0.21")!)
        #expect(CostText.requestAlert(estimate: est, decision: .init(needsConfirmation: false, overBudget: false),
                                      spent: 1, budget: nil) == nil)
        #expect(CostText.requestAlert(estimate: est, decision: .init(needsConfirmation: true, overBudget: false),
                                      spent: 1, budget: nil) == "This request is about $0.21. Generate?")
        #expect(CostText.requestAlert(estimate: est, decision: .init(needsConfirmation: false, overBudget: true),
                                      spent: 5, budget: 4)
                == "This book has spent $5.00 of its $4.00 budget. Generate anyway?")
        #expect(CostText.requestAlert(estimate: est, decision: .init(needsConfirmation: true, overBudget: true),
                                      spent: 5, budget: 4)
                == "This request is about $0.21. This book has spent $5.00 of its $4.00 budget. Generate anyway?")
        #expect(CostText.requestAlert(estimate: est, decision: .init(needsConfirmation: true, overBudget: false),
                                      spent: 1, budget: nil, question: CostConfirmKind.checkConsistency.question)
                == "This request is about $0.21. Check this picture?")
        #expect(CostText.requestAlert(estimate: est, decision: .init(needsConfirmation: false, overBudget: true),
                                      spent: 5, budget: 4, question: CostConfirmKind.regionEdit.question)
                == "This book has spent $5.00 of its $4.00 budget. Edit this region anyway?")
    }

    @Test func batchAlertAlwaysStatesCountAndCost() {
        let est = CostEstimate(amount: Decimal(string: "0.30")!)
        #expect(CostText.batchAlert(count: 5, estimate: est, decision: .init(needsConfirmation: false, overBudget: false),
                                    spent: 0, budget: nil) == "5 pictures, about $0.30.")
        #expect(CostText.batchAlert(count: 1, estimate: .unknown, decision: .init(needsConfirmation: false, overBudget: false),
                                    spent: 0, budget: nil) == "1 picture, cost unknown.")
    }

    @Test func parsesMoneyFields() {
        #expect(CostText.parse("") == .empty)
        #expect(CostText.parse(" $2.50 ") == .value(Decimal(string: "2.5")!))
        #expect(CostText.parse("-1") == .invalid)
        #expect(CostText.parse("abc") == .invalid)
    }
}
