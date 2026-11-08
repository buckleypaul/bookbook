import BBAICore
import BBModel
import Foundation

// Phase 9 contract (main thread). A §7.11 `RefusalAdvisor` and A §7.1 catalog additions.
// Implementations: advisor/catalog lane (RefusalAdvisor.swift, ModelCatalog.swift).

/// Plain-language advice for a failed request. Provider wording is never parsed for advice;
/// it's shown only under Details (`details`).
public struct FailureAdvice: Hashable, Sendable {
    public var headline: String
    public var explanation: String
    /// Suggested fixes, best guesses worded as such ("Try removing the word 'bath'.").
    public var fixes: [String]
    /// The provider console page for billing/key/verification problems.
    public var link: URL?
    /// Offer "Retry with <other provider>" when another provider is configured (never for
    /// key/billing/verification failures).
    public var offersOtherProvider: Bool
    /// "Details": HTTP status, code and the redacted raw body. Never contains the key.
    public var details: String?

    public init(headline: String, explanation: String, fixes: [String] = [], link: URL? = nil,
                offersOtherProvider: Bool = false, details: String? = nil) {
        self.headline = headline
        self.explanation = explanation
        self.fixes = fixes
        self.link = link
        self.offersOtherProvider = offersOtherProvider
        self.details = details
    }
}

/// Facts the advisor rules look at besides the error.
public struct AdviceContext: Hashable, Sendable {
    public var provider: ProviderID
    /// What was sent (prompt, story text, references); nil if the failure came before assembly.
    public var report: AssemblyReport?
    /// A reference flagged as a real-person photo when imported (Phase 10 sets this; false until then).
    public var includesRealPersonPhoto: Bool

    public init(provider: ProviderID, report: AssemblyReport?, includesRealPersonPhoto: Bool = false) {
        self.provider = provider
        self.report = report
        self.includesRealPersonPhoto = includesRealPersonPhoto
    }
}

/// A user-defined model ID that copies a catalog family (A §7.1 item 3). Stored in Settings.
public struct CustomModelSpec: Hashable, Codable, Sendable, Identifiable {
    public var provider: ProviderID
    public var id: String
    /// A bundled catalog model ID whose capabilities and prices are copied.
    public var copiesFrom: String

    public init(provider: ProviderID, id: String, copiesFrom: String) {
        self.provider = provider
        self.id = id
        self.copiesFrom = copiesFrom
    }
}

/// A model's availability after a list-models call (A §7.1 item 1).
public enum ModelAvailability: Hashable, Sendable {
    /// Not checked yet (no key, or Settings hasn't been opened).
    case unknown
    case available
    /// Missing from the provider's list. `successor` is the catalog's suggested replacement.
    case unavailable(successor: String?)
}
