import BBAICore
import BBModel
import Foundation

/// How a failed provider request is written to the ledger (A §7.10). Shared by the generation
/// queue and the Layouts chat, which sends outside the queue.
public enum QueueLedgerRule: Hashable, Sendable {
    /// No request reached the provider (e.g. no key stored): no ledger line.
    case none
    /// The provider answered with an error status, which neither provider bills: $0, basis actual.
    case free
    /// Unknown whether it was billed (cancelled, timed out, transport failure, or an answer with
    /// no error status): the estimate, basis estimate.
    case estimate(CostStatus)

    public static func forFailure(_ error: ProviderError) -> QueueLedgerRule {
        switch error {
        case .missingKey, .offline:
            // `.offline` means nothing was sent (no usable network), so nothing can be billed.
            return .none
        case .cancelled:
            return .estimate(.cancelled)
        case .timeout:
            return .estimate(.failed)
        case .invalidKey, .verificationRequired, .regionUnsupported, .billing, .rateLimited, .refused,
             .invalidRequest, .modelUnavailable:
            // Always an error response (4xx), with or without the raw body.
            return .free
        case let .transient(raw), let .noImage(raw), let .unknown(raw):
            // A raw status of 4xx/5xx means the provider rejected it; anything else (no response,
            // or a 200 without an image) may have been billed.
            if let status = raw?.status, status >= 400 { return .free }
            return .estimate(.failed)
        }
    }

    /// The ledger line's figures; nil for `.none` (no line).
    public var charge: LedgerCharge? {
        switch self {
        case .none: nil
        case .free: .free
        case let .estimate(status): .estimate(status)
        }
    }
}

/// A ledger line's status, basis and actual amount (A §7.10).
public struct LedgerCharge: Hashable, Sendable {
    public var status: CostStatus
    public var basis: CostBasis
    public var actual: Decimal?

    public init(status: CostStatus, basis: CostBasis, actual: Decimal?) {
        self.status = status
        self.basis = basis
        self.actual = actual
    }

    /// A completed request: `usage` priced under `model` (basis actual), or the estimate when
    /// there's no usage or no price entry (`actual` nil). Shared by the queue and the Layouts chat.
    public static func completed(usage: TokenUsage?, provider: ProviderID, model: String,
                                 pricing: some CostPricing) -> LedgerCharge {
        let actual = usage.flatMap { pricing.actualCost(of: $0, provider: provider, model: model) }
        return LedgerCharge(status: .completed, basis: actual == nil ? .estimate : .actual, actual: actual)
    }

    /// An error response: $0, basis actual.
    public static let free = LedgerCharge(status: .failed, basis: .actual, actual: 0)

    /// Unknown whether it was billed: the estimate.
    public static func estimate(_ status: CostStatus) -> LedgerCharge {
        LedgerCharge(status: status, basis: .estimate, actual: nil)
    }
}

extension CostRecord {
    /// One provider request's ledger line (A §7.10). `estimated` is the estimate's amount (0 when
    /// unknown). An actual basis is dated by the current price list; an estimate by the list the
    /// estimate used, else the current one.
    public init(at: Date, kind: CostKind, provider: ProviderID, model: String, quality: QualityLevel?,
                target: GenerationTarget?, charge: LedgerCharge, estimate: CostEstimate,
                currentPriceListAsOf: String?, queueItemID: QueueItemID? = nil) {
        self.init(at: at, kind: kind, provider: provider, model: model, quality: quality, target: target,
                  status: charge.status, estimated: estimate.amount ?? 0, actual: charge.actual, basis: charge.basis,
                  priceListAsOf: charge.basis == .actual
                      ? currentPriceListAsOf : (estimate.priceListAsOf ?? currentPriceListAsOf),
                  queueItemID: queueItemID)
    }
}
