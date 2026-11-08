import BBAICore
import BBModel
import Foundation

/// Prices reported token usage from a `PriceList` (A §7.10 "Actual cost").
public struct CostCalculator: CostPricing {
    public let priceList: PriceList

    public init(priceList: PriceList) { self.priceList = priceList }

    public var priceListAsOf: String? { priceList.asOf }

    /// `model` is a pricing model ID (`CatalogModel.pricingModelID`). Missing rates count as 0;
    /// nil when the list has no entry for the model.
    public func actualCost(of usage: TokenUsage, provider: ProviderID, model: String) -> Decimal? {
        guard let entry = priceList.entry(provider: provider, model: model) else { return nil }
        let rates = entry.perMillionTokens
        let textIn = rates["textIn"] ?? 0
        let imageIn = rates["imageIn"] ?? 0
        // OpenAI reports `cached_tokens` as a subset of the input tokens (BBOpenAI maps it to
        // `cachedInputTokens` alongside the full text/image split). The split of the cached
        // count between text and image is not reported, so attribute it to text first (the
        // prompt prefix), then image, clamped so no count goes negative. The cached share is
        // charged at the cached rate and only the remainder at the full rate.
        let cachedText = min(max(usage.cachedInputTokens, 0), usage.inputTextTokens)
        let cachedImage = min(max(usage.cachedInputTokens, 0) - cachedText, usage.inputImageTokens)
        let total = textIn * Decimal(usage.inputTextTokens - cachedText)
            + (rates["cachedTextIn"] ?? textIn) * Decimal(cachedText)
            + imageIn * Decimal(usage.inputImageTokens - cachedImage)
            + (rates["cachedImageIn"] ?? imageIn) * Decimal(cachedImage)
            + (rates["imageOut"] ?? 0) * Decimal(usage.outputImageTokens)
            + (rates["textOut"] ?? 0) * Decimal(usage.outputTextTokens)
        return total / 1_000_000
    }
}
