import Foundation

// Phase 12 contract (main thread): consistency-check results stored on a version
// (architecture.md §7.8, PD §8.9).

public enum ConsistencySeverity: String, Codable, Sendable {
    case minor, major
}

/// One difference reported by the vision model (A §7.8 output schema).
public struct ConsistencyDifference: Hashable, Codable, Sendable {
    /// The asset's name as the model reported it, or nil for style/general differences.
    public var asset: String?
    public var aspect: String
    public var observed: String
    public var expected: String
    public var severity: ConsistencySeverity

    public init(asset: String?, aspect: String, observed: String, expected: String, severity: ConsistencySeverity) {
        self.asset = asset
        self.aspect = aspect
        self.observed = observed
        self.expected = expected
        self.severity = severity
    }
}

/// What a consistency check sent, for Version details (A §11: everything sent is shown).
public struct ConsistencySent: Hashable, Codable, Sendable {
    /// The exact system + user text sent.
    public var promptSent: String
    /// The checked image first, then the references, in the order sent.
    public var imagesSent: [SentReference]
    /// Every wire parameter besides the prompt and images (e.g. `detail`, `store`, `response_format`).
    public var parametersSent: [String: String]

    public init(promptSent: String, imagesSent: [SentReference], parametersSent: [String: String] = [:]) {
        self.promptSent = promptSent
        self.imagesSent = imagesSent
        self.parametersSent = parametersSent
    }
}

/// The latest consistency check of a version.
public struct ConsistencyReport: Hashable, Codable, Sendable {
    public var checkedAt: Date
    public var provider: ProviderID
    public var model: String
    public var consistent: Bool
    public var differences: [ConsistencyDifference]
    /// Whether this result passes the catalog thresholds (`ConsistencyThresholds.warns`),
    /// computed when the result is delivered.
    public var warns: Bool
    /// The user dismissed the warning (PD §8.9). The badge and flag stay hidden.
    public var dismissed: Bool
    public var sent: ConsistencySent
    /// The ledger entry for the check.
    public var cost: CostRecordID?
    public var usage: TokenUsage?

    /// True when the version should show the warning badge.
    public var showsWarning: Bool { warns && !dismissed }

    public init(checkedAt: Date, provider: ProviderID, model: String, consistent: Bool,
                differences: [ConsistencyDifference], warns: Bool, dismissed: Bool = false,
                sent: ConsistencySent, cost: CostRecordID? = nil, usage: TokenUsage? = nil) {
        self.checkedAt = checkedAt
        self.provider = provider
        self.model = model
        self.consistent = consistent
        self.differences = differences
        self.warns = warns
        self.dismissed = dismissed
        self.sent = sent
        self.cost = cost
        self.usage = usage
    }
}
