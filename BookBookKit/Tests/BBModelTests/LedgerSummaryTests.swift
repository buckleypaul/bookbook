import Foundation
import Testing
@testable import BBModel

@Suite struct LedgerSummaryTests {
    private func record(_ t: Double, kind: CostKind = .image, estimated: Decimal, actual: Decimal? = nil,
                        basis: CostBasis = .estimate) -> CostRecord {
        CostRecord(at: Date(timeIntervalSince1970: t), kind: kind, provider: .openai, model: "m", quality: .draft,
                   target: nil, status: .completed, estimated: estimated, actual: actual, basis: basis, priceListAsOf: nil)
    }

    @Test func emptyLedger() {
        let s = LedgerSummary(records: [])
        #expect(s.total == 0)
        #expect(s.byKind.isEmpty)
        #expect(s.recent.isEmpty)
        #expect(!s.includesEstimates)
    }

    @Test func totalsUseActualWhenBasisIsActual() {
        let s = LedgerSummary(records: [
            record(1, estimated: 0.10, actual: 0.06, basis: .actual),
            record(2, kind: .consistency, estimated: 0.02),
            record(3, kind: .image, estimated: 0.05, actual: 0.04, basis: .actual),
        ])
        #expect(s.total == Decimal(string: "0.12"))
        #expect(s.byKind[.image] == Decimal(string: "0.10"))
        #expect(s.byKind[.consistency] == Decimal(string: "0.02"))
        #expect(s.byKind[.template] == nil)
        #expect(s.includesEstimates)
    }

    @Test func allActualHasNoEstimates() {
        let s = LedgerSummary(records: [record(1, estimated: 1, actual: 0.5, basis: .actual)])
        #expect(!s.includesEstimates)
    }

    @Test func zeroDollarEstimateDoesNotCount() {
        // A failed request recorded at $0 is not an estimate in the total.
        let s = LedgerSummary(records: [record(1, estimated: 0), record(2, estimated: 1, actual: 1, basis: .actual)])
        #expect(!s.includesEstimates)
    }

    @Test func recentIsNewestFirstAndLimited() {
        let records = (1...5).map { record(Double($0), estimated: Decimal($0)) }.shuffled()
        let s = LedgerSummary(records: records, recentLimit: 3)
        #expect(s.recent.map(\.at.timeIntervalSince1970) == [5, 4, 3])
        #expect(s.total == 15)
        #expect(LedgerSummary(records: records, recentLimit: 0).recent.isEmpty)
    }
}
