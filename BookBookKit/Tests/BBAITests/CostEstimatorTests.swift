import BBAICore
import BBModel
import Foundation
import Testing
@testable import BBAI

@Suite struct CostEstimatorTests {
    private let sunburst = "gpt-image-2.5-sunburst"

    private func model() throws -> CatalogModel {
        try #require(try ModelCatalog.bundled().imageModel(provider: .openai, id: sunburst))
    }

    private func input(_ size: PixelSize, quality: QualityLevel = .draft, images: [PixelSize] = [], chars: Int = 0) throws -> ImageEstimateInput {
        ImageEstimateInput(model: try model(), quality: quality, outputSize: size, inputImageSizes: images, promptCharacters: chars)
    }

    private func sq(_ n: Int) -> PixelSize { PixelSize(width: n, height: n) }

    @Test func exactTableHit() throws {
        let list = try PriceList.bundled()
        let est = CostEstimator.estimate(try input(sq(1024)), priceList: list)
        // 196 output tokens at $30 per million.
        #expect(est.amount == Decimal(string: "0.00588"))
        #expect(est.extrapolated == false)
        #expect(est.priceListAsOf == list.entry(provider: .openai, model: sunburst)?.asOf)
        let high = CostEstimator.estimate(try input(sq(1024), quality: .high), priceList: list)
        #expect(high.amount == Decimal(string: "0.05268"))  // 1756 * 30 / 1e6
    }

    @Test func nonProportionalSizesUseTheirOwnEntries() throws {
        let list = try PriceList.bundled()
        let est = CostEstimator.estimate(try input(PixelSize(width: 1024, height: 1536)), priceList: list)
        #expect(est.amount == Decimal(string: "0.00474"))  // 158 tokens
        #expect(est.extrapolated == false)
    }

    @Test func nearestEntryIsExtrapolated() throws {
        let list = try PriceList.bundled()
        // 1100x1000 = 1.1M px: nearest low entry is 1024x1024 (196), not 1232x816.
        let est = CostEstimator.estimate(try input(PixelSize(width: 1100, height: 1000)), priceList: list)
        #expect(est.amount == Decimal(string: "0.00588"))
        #expect(est.extrapolated)
        // Medium has only one entry, so everything maps to it.
        let med = CostEstimator.estimate(try input(sq(512), quality: .standard), priceList: list)
        #expect(med.amount == Decimal(string: "0.01317"))  // 439 tokens
        #expect(med.extrapolated)
    }

    @Test func nearestTieTakesLargerTokens() throws {
        var entry = PriceEntry(provider: .openai, model: sunburst, asOf: "t", perMillionTokens: ["imageOut": 1_000_000],
                               estimation: .init(outputImageTokens: ["low@100x100": 10, "low@100x300": 30, "high@200x200": 999]))
        entry.placeholder = nil
        let list = PriceList(asOf: "t", entries: [entry])
        // 100x200 = 20k px is equidistant from 10k and 30k.
        let est = CostEstimator.estimate(try input(PixelSize(width: 100, height: 200)), priceList: list)
        #expect(est.amount == 30)
        #expect(est.extrapolated)
    }

    @Test func inputImageTokensFromTable() throws {
        let list = try PriceList.bundled()
        let est = CostEstimator.estimate(try input(sq(1024), images: [sq(1024), sq(256), sq(128)]), priceList: list)
        // 196 out (5880) + (1024 + 256 + 64) in at $8 (10752) = 16632 / 1e6
        #expect(est.amount == Decimal(string: "0.016632"))
        #expect(est.extrapolated == false)
    }

    @Test func patchRuleForUnmeasuredSizes() throws {
        #expect(CostEstimator.patchTokens(PixelSize(width: 1536, height: 1024)) == 32 * 22)
        #expect(CostEstimator.patchTokens(sq(2048)) == 32 * 32)
        #expect(CostEstimator.patchTokens(sq(100)) == 7 * 7)  // small images are not upscaled
        let list = try PriceList.bundled()
        let est = CostEstimator.estimate(try input(sq(1024), images: [sq(2048)]), priceList: list)
        #expect(est.amount == Decimal(string: "0.014072"))  // (196*30 + 1024*8) / 1e6 -> 5880 + 8192
        #expect(est.extrapolated)
    }

    @Test func measuredLandscapeReference() throws {
        // SP9 measured 1536 input tokens for a 1536x1024 reference (the patch rule predicts 704).
        let list = try PriceList.bundled()
        let est = CostEstimator.estimate(try input(sq(1024), images: [PixelSize(width: 1536, height: 1024)]), priceList: list)
        #expect(est.amount == Decimal(string: "0.018168"))  // 5880 + 1536*8 (12288)
        #expect(est.extrapolated == false)
    }

    @Test func textTokensRoundUp() throws {
        let list = try PriceList.bundled()
        let est = CostEstimator.estimate(try input(sq(1024), chars: 96), priceList: list)
        // ceil(96 * 0.27) = 26 text tokens at $5.
        #expect(est.amount == Decimal(string: "0.00601"))
    }

    @Test func unknownModelIsUnknown() throws {
        let list = PriceList(asOf: "t", entries: [])
        #expect(CostEstimator.estimate(try input(sq(1024)), priceList: list) == .unknown)
        // An entry without an output table can't be estimated either.
        let bare = PriceList(asOf: "t", entries: [
            PriceEntry(provider: .openai, model: sunburst, asOf: "t", perMillionTokens: ["imageOut": 30])])
        #expect(CostEstimator.estimate(try input(sq(1024)), priceList: bare).amount == nil)
    }

    @Test func customModelPricedAsItsFamily() throws {
        var custom = try model()
        custom.id = "my-custom-image"
        custom.copiesFrom = sunburst
        let list = try PriceList.bundled()
        let est = CostEstimator.estimate(
            ImageEstimateInput(model: custom, quality: .draft, outputSize: sq(1024), promptCharacters: 0), priceList: list)
        #expect(est.amount == Decimal(string: "0.00588"))
    }

    // MARK: Measured SP-2 / SP-3 costs

    @Test func matchesSP2Measured() throws {
        let list = try PriceList.bundled()
        let calc = CostCalculator(priceList: list)
        // (size, text tokens in, image tokens out) from the recorded usage.
        let measured: [(PixelSize, Int, Int)] = [
            (sq(1024), 26, 196), (PixelSize(width: 1024, height: 1536), 26, 158), (PixelSize(width: 1232, height: 816), 26, 133),
        ]
        for (size, textIn, out) in measured {
            let actual = try #require(calc.actualCost(of: TokenUsage(inputTextTokens: textIn, outputImageTokens: out),
                                                      provider: .openai, model: sunburst))
            let est = try #require(CostEstimator.estimate(try input(size, chars: 96), priceList: list).amount)
            let ratio = NSDecimalNumber(decimal: est / actual).doubleValue
            #expect(abs(ratio - 1) < 0.15, "estimate \(est) vs measured \(actual) at \(size)")
        }
    }

    @Test func matchesSP3EditMeasured() throws {
        let list = try PriceList.bundled()
        let actual = try #require(CostCalculator(priceList: list).actualCost(
            of: TokenUsage(inputTextTokens: 95, inputImageTokens: 1792, outputImageTokens: 196),
            provider: .openai, model: sunburst))
        let est = try #require(CostEstimator.estimate(
            try input(sq(1024), images: [sq(1024), sq(256), sq(256), sq(256)], chars: 351), priceList: list).amount)
        let ratio = NSDecimalNumber(decimal: est / actual).doubleValue
        #expect(abs(ratio - 1) < 0.15)
    }

    @Test func twelveDraftBatchNearSevenCents() throws {
        let list = try PriceList.bundled()
        let one = CostEstimator.estimate(try input(sq(1024), chars: 96), priceList: list)
        let batch = CostEstimate.total(Array(repeating: one, count: 12))
        let total = NSDecimalNumber(decimal: try #require(batch.amount)).doubleValue
        #expect(abs(total - 0.07) < 0.01)
    }

    // MARK: CostEstimate.total

    @Test func totalSumsKnownPartsAndFlagsUnknown() {
        let a = CostEstimate(amount: 1, priceListAsOf: "d")
        let b = CostEstimate(amount: 2, extrapolated: true)
        #expect(CostEstimate.total([a, b]) == CostEstimate(amount: 3, extrapolated: true, priceListAsOf: "d"))
        let mixed = CostEstimate.total([a, .unknown])
        #expect(mixed.amount == 1)
        #expect(mixed.extrapolated)
        #expect(CostEstimate.total([.unknown, .unknown]).amount == nil)
        #expect(CostEstimate.total([]).amount == 0)
    }

    // MARK: estimateInput

    @Test func estimateInputForNewImage() throws {
        let catalog = try ModelCatalog.bundled()
        let book = SliceBook.make()
        let result = try #require(CostEstimator.estimateInput(intent: intent(), target: book.target, content: book.content, catalog: catalog))
        #expect(result.model.id == sunburst)
        #expect(result.inputImageSizes.isEmpty)
        #expect(result.promptCharacters > 100)
        #expect(result.outputSize.width * result.outputSize.height > 0)
        let est = CostEstimator.estimate(result, priceList: try PriceList.bundled())
        #expect(est.amount != nil)
    }

    @Test func estimateInputNilForUnknownModelOrTarget() throws {
        let catalog = try ModelCatalog.bundled()
        let book = SliceBook.make()
        var other = intent()
        other.model = "not-a-model"
        #expect(CostEstimator.estimateInput(intent: other, target: book.target, content: book.content, catalog: catalog) == nil)
        let gone = GenerationTarget.pageBox(PageID(), BoxID())
        #expect(CostEstimator.estimateInput(intent: intent(), target: gone, content: book.content, catalog: catalog) == nil)
    }
}
