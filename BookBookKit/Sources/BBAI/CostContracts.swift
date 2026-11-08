import BBAICore
import BBModel
import Foundation

// Phase 9 contract (main thread). A §7.10. Implementations: cost lane (CostEstimator.swift,
// CostCalculator.swift, CostPolicy.swift, PriceList loading). Amounts are USD `Decimal`.

// MARK: - Price list (bundled `PriceList.json`; a user copy takes precedence)

/// Mirrors `PriceList.json`. Round-trips unknown-free: encoding a decoded list must decode to
/// an equal value (the Settings editor saves it as the user's `pricelist.json`).
public struct PriceList: Hashable, Codable, Sendable {
    public var schemaNote: String?
    public var asOf: String
    public var entries: [PriceEntry]

    public init(schemaNote: String? = nil, asOf: String, entries: [PriceEntry]) {
        self.schemaNote = schemaNote
        self.asOf = asOf
        self.entries = entries
    }

    public func entry(provider: ProviderID, model: String) -> PriceEntry? {
        entries.first { $0.provider == provider && $0.model == model }
    }
}

public struct PriceEntry: Hashable, Codable, Sendable, Identifiable {
    public var provider: ProviderID
    public var model: String
    public var currency: String
    public var asOf: String
    /// True for figures not yet checked against the provider's pricing page.
    public var placeholder: Bool?
    /// Keys: `textIn`, `imageIn`, `imageOut`, `cachedImageIn`, `cachedTextIn`, `textOut`.
    public var perMillionTokens: [String: Decimal]
    /// Gemini-style per-image prices keyed by image size (`1K`, `2K`, `4K`). Unused until Phase 13.
    public var perImage: [String: Decimal]?
    public var estimation: Estimation?

    public var id: String { "\(provider.rawValue)/\(model)" }

    public struct Estimation: Hashable, Codable, Sendable {
        /// `"<quality param>@<W>x<H>"` → measured output image tokens (e.g. `low@1024x1024`).
        public var outputImageTokens: [String: Int]?
        /// `"<W>x<H>"` → measured input tokens for one reference image of that size.
        public var inputImageTokens: [String: Int]?
        public var textTokensPerPromptChar: Double?
        public var typicalTemplateRequest: TypicalRequest?
        public var typicalConsistencyRequest: TypicalRequest?
        public var notes: String?

        public init(outputImageTokens: [String: Int]? = nil, inputImageTokens: [String: Int]? = nil,
                    textTokensPerPromptChar: Double? = nil, typicalTemplateRequest: TypicalRequest? = nil,
                    typicalConsistencyRequest: TypicalRequest? = nil, notes: String? = nil) {
            self.outputImageTokens = outputImageTokens
            self.inputImageTokens = inputImageTokens
            self.textTokensPerPromptChar = textTokensPerPromptChar
            self.typicalTemplateRequest = typicalTemplateRequest
            self.typicalConsistencyRequest = typicalConsistencyRequest
            self.notes = notes
        }
    }

    /// Field names follow the JSON (`inputTokens`, `inputTokensTwoLowDetailImages`,
    /// `outputTokens`, `reasoningTokensIncluded`).
    public struct TypicalRequest: Hashable, Codable, Sendable {
        public var inputTokens: Int?
        public var inputTokensTwoLowDetailImages: Int?
        public var outputTokens: Int?
        public var reasoningTokensIncluded: Bool?
    }

    public init(provider: ProviderID, model: String, currency: String = "USD", asOf: String,
                placeholder: Bool? = nil, perMillionTokens: [String: Decimal], perImage: [String: Decimal]? = nil,
                estimation: Estimation? = nil) {
        self.provider = provider
        self.model = model
        self.currency = currency
        self.asOf = asOf
        self.placeholder = placeholder
        self.perMillionTokens = perMillionTokens
        self.perImage = perImage
        self.estimation = estimation
    }
}

public enum PriceListError: Error, Equatable, Sendable {
    case missingResource
    case malformed(String)
}

// MARK: - Estimates

public struct CostEstimate: Hashable, Codable, Sendable {
    /// nil when the model has no price entry ("cost unknown").
    public var amount: Decimal?
    /// True when a size wasn't in the measured table and the nearest entry was used.
    public var extrapolated: Bool
    public var priceListAsOf: String?

    public init(amount: Decimal?, extrapolated: Bool = false, priceListAsOf: String? = nil) {
        self.amount = amount
        self.extrapolated = extrapolated
        self.priceListAsOf = priceListAsOf
    }

    public static let unknown = CostEstimate(amount: nil)

    /// Sum for batches. Unknown parts make the total's `amount` nil only if every part is
    /// unknown; otherwise the known parts are summed and `extrapolated` is set.
    public static func total(_ parts: [CostEstimate]) -> CostEstimate {
        let known = parts.compactMap(\.amount)
        guard !known.isEmpty else { return parts.isEmpty ? CostEstimate(amount: 0) : .unknown }
        return CostEstimate(amount: known.reduce(0, +),
                            extrapolated: parts.contains { $0.extrapolated || $0.amount == nil },
                            priceListAsOf: parts.first { $0.priceListAsOf != nil }?.priceListAsOf)
    }
}

/// What the estimator needs for one image request, known before images are loaded.
public struct ImageEstimateInput: Hashable, Sendable {
    public var model: CatalogModel
    public var quality: QualityLevel
    public var outputSize: PixelSize
    /// Pixel sizes of every image uploaded (base image first if refining, then references).
    public var inputImageSizes: [PixelSize]
    public var promptCharacters: Int

    public init(model: CatalogModel, quality: QualityLevel, outputSize: PixelSize,
                inputImageSizes: [PixelSize] = [], promptCharacters: Int) {
        self.model = model
        self.quality = quality
        self.outputSize = outputSize
        self.inputImageSizes = inputImageSizes
        self.promptCharacters = promptCharacters
    }
}

/// Prices reported usage (A §7.10 "Actual cost"). The queue depends only on this protocol, so
/// it can be faked in tests. `CostCalculator` is the real conformance.
public protocol CostPricing: Sendable {
    /// nil if the model has no price entry.
    func actualCost(of usage: TokenUsage, provider: ProviderID, model: String) -> Decimal?
    var priceListAsOf: String? { get }
}

/// What `CostPolicy` decides before enqueueing (A §7.10 "Policies").
public struct CostDecision: Hashable, Sendable {
    /// The estimate is above the Settings threshold: ask before enqueueing.
    public var needsConfirmation: Bool
    /// The book's total is already above its budget: warn (never block).
    public var overBudget: Bool

    public init(needsConfirmation: Bool, overBudget: Bool) {
        self.needsConfirmation = needsConfirmation
        self.overBudget = overBudget
    }
}
