import Foundation
import Testing
@testable import BBModel

@Suite struct Phase16bLedgerSummaryTests {
    private func record(estimated: Decimal, basis: CostBasis) -> CostRecord {
        CostRecord(at: Date(), kind: .image, provider: .openai, model: "m", quality: .draft, target: nil,
                   status: .completed, estimated: estimated, actual: nil, basis: basis, priceListAsOf: nil)
    }

    @Test func singleZeroEstimateIncludesEstimates() {
        #expect(LedgerSummary(records: [record(estimated: 0, basis: .estimate)]).includesEstimates)
    }

    @Test func skippedLinesAreCarried() {
        #expect(LedgerSummary(records: [], skippedLines: 2).skippedLines == 2)
        #expect(LedgerSummary().skippedLines == 0)
    }
}
