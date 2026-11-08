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
        let imageIn = rates["imageIn"] ?? 0
        let total = (rates["textIn"] ?? 0) * Decimal(usage.inputTextTokens)
            + imageIn * Decimal(usage.inputImageTokens)
            + (rates["cachedImageIn"] ?? imageIn) * Decimal(usage.cachedInputTokens)
            + (rates["imageOut"] ?? 0) * Decimal(usage.outputImageTokens)
            + (rates["textOut"] ?? 0) * Decimal(usage.outputTextTokens)
        return total / 1_000_000
    }
}
