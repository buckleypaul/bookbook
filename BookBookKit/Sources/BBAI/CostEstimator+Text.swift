import BBAICore
import BBModel
import Foundation

// Phase 12. A §7.10.

extension CostEstimator {
    /// A template request, from the prompt length and the price list's `typicalTemplateRequest`
    /// (reasoning tokens count as output).
    public static func estimate(layout request: LayoutRequest, priceList: PriceList) -> CostEstimate {
        estimateText(model: request.model, characters: request.system.count + request.user.count,
                     priceList: priceList) { $0.typicalTemplateRequest }
    }

    /// A text-styling request (A §7.13), from the prompt length and the price list's
    /// `typicalTextStyleRequest` (else `typicalTemplateRequest`). The decoration it may queue is
    /// estimated separately, as an image request.
    public static func estimate(textStyle request: TextStyleRequest, priceList: PriceList) -> CostEstimate {
        estimateText(model: request.model, characters: request.system.count + request.user.count,
                     priceList: priceList) { $0.typicalTextStyleRequest ?? $0.typicalTemplateRequest }
    }

    /// A structured-output text request: input from the prompt length (the typical request's
    /// count when the entry has no per-character rate), output from the typical request.
    private static func estimateText(model: CatalogTextModel, characters: Int, priceList: PriceList,
                                     typical pick: (PriceEntry.Estimation) -> PriceEntry.TypicalRequest?) -> CostEstimate {
        guard let entry = priceList.entry(provider: model.provider, model: model.id),
              let typical = entry.estimation.flatMap(pick), let output = typical.outputTokens
        else { return .unknown }
        let input: Int
        if let perChar = entry.estimation?.textTokensPerPromptChar {
            input = Int((Double(characters) * perChar).rounded(.up))
        } else {
            input = typical.inputTokens ?? Int((Double(characters) * 0.27).rounded(.up))
        }
        let rates = entry.perMillionTokens
        let total = (rates["textIn"] ?? 0) * Decimal(input) + (rates["textOut"] ?? 0) * Decimal(output)
        return CostEstimate(amount: total / 1_000_000, priceListAsOf: entry.asOf)
    }

    /// A consistency check sending `imageCount` low-detail images (checked image + references),
    /// from the price list's `typicalConsistencyRequest`.
    public static func estimateConsistency(model: CatalogTextModel, imageCount: Int,
                                           priceList: PriceList) -> CostEstimate {
        guard let entry = priceList.entry(provider: model.provider, model: model.id),
              let typical = entry.estimation?.typicalConsistencyRequest,
              let twoImages = typical.inputTokensTwoLowDetailImages, let output = typical.outputTokens
        else { return .unknown }
        let typicalImages = 2
        let count = max(0, imageCount)
        let input = count == typicalImages
            ? Decimal(twoImages)
            : Decimal(twoImages) * Decimal(count) / Decimal(typicalImages)
        let rates = entry.perMillionTokens
        let inputRate = rates["imageIn"] ?? rates["textIn"] ?? 0
        let total = inputRate * input + (rates["textOut"] ?? 0) * Decimal(output)
        return CostEstimate(amount: total / 1_000_000, extrapolated: count != typicalImages, priceListAsOf: entry.asOf)
    }
}
