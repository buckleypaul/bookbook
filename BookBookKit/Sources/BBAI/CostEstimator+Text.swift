import BBAICore
import BBModel
import Foundation

// Phase 12 contract (main thread); bodies filled by the BBAI lane. A §7.10.

extension CostEstimator {
    /// A template request, from the prompt length and the price list's `typicalTemplateRequest`
    /// (reasoning tokens count as output).
    public static func estimate(layout request: LayoutRequest, priceList: PriceList) -> CostEstimate {
        fatalError("Phase 12: layout estimate not implemented")
    }

    /// A consistency check sending `imageCount` low-detail images (checked image + references),
    /// from the price list's `typicalConsistencyRequest`.
    public static func estimateConsistency(model: CatalogTextModel, imageCount: Int,
                                           priceList: PriceList) -> CostEstimate {
        fatalError("Phase 12: consistency estimate not implemented")
    }
}
