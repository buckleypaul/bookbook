import BBModel
import Foundation
import Testing
@testable import BBStore

@Suite struct CostRecordLedgerTests {
    private func record(_ t: Double, actual: Decimal?) -> CostRecord {
        CostRecord(at: Date(timeIntervalSince1970: 1_800_000_000 + t), kind: .image, provider: .openai,
                   model: "gpt-image-2.5-sunburst", quality: .draft, target: .pageBox(PageID(), BoxID()),
                   status: .completed, estimated: Decimal(string: "0.00601")!, actual: actual,
                   basis: actual == nil ? .estimate : .actual, priceListAsOf: "2026-11-07", queueItemID: QueueItemID())
    }

    @Test func recordsRoundTripThroughLedger() throws {
        let ledger = CostLedger(packageURL: try makeTempDir())
        let a = record(1, actual: Decimal(string: "0.006"))
        let b = record(2, actual: nil)
        try ledger.append(a)
        try ledger.append(b)
        let read = try ledger.records(CostRecord.self)
        #expect(read == [a, b])
        #expect(read[0].amount == Decimal(string: "0.006"))
        #expect(read[1].amount == Decimal(string: "0.00601"))
    }

    @Test func summaryFromLedger() throws {
        let ledger = CostLedger(packageURL: try makeTempDir())
        try ledger.append(record(1, actual: 1))
        try ledger.append(record(2, actual: nil))
        let summary = LedgerSummary(records: try ledger.records(CostRecord.self))
        #expect(summary.total == Decimal(string: "1.00601"))
        #expect(summary.includesEstimates)
        #expect(summary.recent.first?.at == Date(timeIntervalSince1970: 1_800_000_002))
    }
}
