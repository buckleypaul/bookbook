import BBAI
import BBAICore
import BBModel
import Foundation

/// The example costs the guided setup shows (PD §8.13), computed from a price list with the
/// same estimator the app uses before every request. Nothing here is hard-coded.
public struct TypicalCosts: Hashable, Sendable {
    public static let imageSize = PixelSize(width: 1024, height: 1024)
    public static let bookPages = 12
    /// A typical prompt, in characters.
    public static let promptCharacters = 600

    public var modelName: String
    public var draftPerImage: Decimal?
    public var standardPerImage: Decimal?
    /// Standard-quality images for `bookPages` pages.
    public var bookAtStandard: Decimal?
    public var priceListAsOf: String?

    public init(model: CatalogModel?, priceList: PriceList) {
        modelName = model?.displayName ?? "the default image model"
        priceListAsOf = priceList.asOf
        guard let model else { return }
        func cost(_ quality: QualityLevel) -> Decimal? {
            CostEstimator.estimate(
                ImageEstimateInput(model: model, quality: quality, outputSize: Self.imageSize,
                                   promptCharacters: Self.promptCharacters),
                priceList: priceList).amount
        }
        draftPerImage = cost(.draft)
        standardPerImage = cost(.standard)
        bookAtStandard = standardPerImage.map { $0 * Decimal(Self.bookPages) }
    }

    public static func format(_ amount: Decimal?) -> String {
        guard let amount else { return "unknown" }
        let value = NSDecimalNumber(decimal: amount).doubleValue
        return value.formatted(.currency(code: "USD").precision(.fractionLength(value < 1 ? 3 : 2)))
    }
}
