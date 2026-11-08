import Foundation

// Phase 9 contract (main thread). Ledger records live in `<package>/costs.jsonl`, one per
// provider request (A §7.10), written through `BBStore.CostLedger`. Amounts are USD.

public enum CostKind: String, Codable, Sendable, CaseIterable {
    case image, consistency, template
}

public enum CostStatus: String, Codable, Sendable {
    case completed, failed, cancelled
}

/// Whether `amount` was priced from reported usage or is the pre-request estimate.
public enum CostBasis: String, Codable, Sendable {
    case actual, estimate
}

/// One line of `costs.jsonl` (A §7.10).
public struct CostRecord: Hashable, Codable, Sendable, Identifiable {
    public var id: CostRecordID
    public var at: Date
    public var kind: CostKind
    public var provider: ProviderID
    public var model: String
    public var quality: QualityLevel?
    public var target: GenerationTarget?
    public var status: CostStatus
    /// The estimate made before the request.
    public var estimated: Decimal
    /// Priced from reported usage; nil when the provider reported none.
    public var actual: Decimal?
    public var basis: CostBasis
    public var priceListAsOf: String?
    /// The queue item that made the request (for Recent Requests and Version details).
    public var queueItemID: QueueItemID?

    public init(id: CostRecordID = CostRecordID(), at: Date, kind: CostKind, provider: ProviderID, model: String,
                quality: QualityLevel?, target: GenerationTarget?, status: CostStatus, estimated: Decimal,
                actual: Decimal?, basis: CostBasis, priceListAsOf: String?, queueItemID: QueueItemID? = nil) {
        self.id = id
        self.at = at
        self.kind = kind
        self.provider = provider
        self.model = model
        self.quality = quality
        self.target = target
        self.status = status
        self.estimated = estimated
        self.actual = actual
        self.basis = basis
        self.priceListAsOf = priceListAsOf
        self.queueItemID = queueItemID
    }

    /// What counts toward the book total: `actual` when the basis is actual, else `estimated`.
    public var amount: Decimal { basis == .actual ? (actual ?? estimated) : estimated }
}

/// Totals computed from a book's ledger (PD §8.12). Derived, never stored.
public struct LedgerSummary: Hashable, Sendable {
    public var total: Decimal
    public var byKind: [CostKind: Decimal]
    /// Newest first.
    public var recent: [CostRecord]
    /// True if any record counted in `total` is an estimate.
    public var includesEstimates: Bool

    public init(total: Decimal = 0, byKind: [CostKind: Decimal] = [:], recent: [CostRecord] = [],
                includesEstimates: Bool = false) {
        self.total = total
        self.byKind = byKind
        self.recent = recent
        self.includesEstimates = includesEstimates
    }

    /// `total` is the sum of `amount` over all records; `recent` holds the newest
    /// `recentLimit` records. Implemented by the cost lane.
    public init(records: [CostRecord], recentLimit: Int = 50) {
        var total: Decimal = 0
        var byKind: [CostKind: Decimal] = [:]
        var estimates = false
        for record in records {
            total += record.amount
            byKind[record.kind, default: 0] += record.amount
            if record.basis == .estimate && record.amount != 0 { estimates = true }
        }
        let recent = records.sorted { $0.at > $1.at }.prefix(max(0, recentLimit))
        self.init(total: total, byKind: byKind, recent: Array(recent), includesEstimates: estimates)
    }
}
