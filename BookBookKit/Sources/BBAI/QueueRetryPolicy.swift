import BBAICore
import BBModel
import Foundation

/// When the queue retries a failed request by itself (A §7.9, §7.11), and how long it waits.
///
/// `.rateLimited`, `.transient` and `.offline` get up to `maxRetries` retries (so
/// `maxRetries + 1` requests); `.noImage` gets `maxNoImageRetries`. Everything else, including
/// `.timeout`, fails at once. The wait before retry *k* (1-based) is `Retry-After` when the
/// provider sent one, else `base · multiplier^(k-1) + jitter · base`; both are capped at `maxDelay`.
public struct QueueRetryPolicy: Hashable, Sendable {
    public var maxRetries: Int
    public var maxNoImageRetries: Int
    public var base: Duration
    public var multiplier: Double
    public var maxDelay: Duration

    public init(maxRetries: Int = 3, maxNoImageRetries: Int = 1, base: Duration = .seconds(2), multiplier: Double = 2,
                maxDelay: Duration = .seconds(120)) {
        self.maxRetries = maxRetries
        self.maxNoImageRetries = maxNoImageRetries
        self.base = base
        self.multiplier = multiplier
        self.maxDelay = maxDelay
    }

    public static let standard = QueueRetryPolicy()

    /// The wait before the next request, or nil if `error` shouldn't be retried after
    /// `retriesSoFar` automatic retries. `jitter` is in 0...1.
    public func delay(after error: ProviderError, retriesSoFar: Int, jitter: Double) -> Duration? {
        let limit: Int
        var retryAfter: Double?
        switch error {
        case let .rateLimited(after, _):
            limit = maxRetries
            retryAfter = after
        case .transient, .offline:
            limit = maxRetries
        case .noImage:
            limit = maxNoImageRetries
        default:
            return nil
        }
        guard retriesSoFar < limit else { return nil }
        if let retryAfter, retryAfter.isFinite, retryAfter >= 0 {
            return min(.seconds(retryAfter), maxDelay)
        }
        let backoff = base * pow(multiplier, Double(retriesSoFar)) + base * min(max(jitter, 0), 1)
        return min(backoff, maxDelay)
    }
}

/// How a provider request's outcome is written to the ledger (A §7.10).
enum QueueLedgerRule: Hashable, Sendable {
    /// No request reached the provider (e.g. no key stored): no ledger line.
    case none
    /// The provider answered with an error status, which neither provider bills: $0, basis actual.
    case free
    /// Unknown whether it was billed (cancelled, timed out, transport failure, or an answer with
    /// no error status): the estimate, basis estimate.
    case estimate(CostStatus)

    static func forFailure(_ error: ProviderError) -> QueueLedgerRule {
        switch error {
        case .missingKey:
            return .none
        case .cancelled:
            return .estimate(.cancelled)
        case .timeout, .offline:
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
}

extension Duration {
    var timeInterval: TimeInterval {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
