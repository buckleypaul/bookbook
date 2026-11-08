import BBModel
import Foundation
import Testing
@testable import BBAI

@Suite struct CostCalculatorTests {
    private func calculator() throws -> CostCalculator { CostCalculator(priceList: try PriceList.bundled()) }

    @Test func pricesSP2LowSquare() throws {
        // SP-2 generations-low-1024x1024 usage: 26 text in, 196 image out.
        let usage = TokenUsage(inputTextTokens: 26, outputImageTokens: 196)
        let cost = try calculator().actualCost(of: usage, provider: .openai, model: "gpt-image-2.5-sunburst")
        #expect(cost == Decimal(string: "0.00601"))
    }

    @Test func pricesSP3EditWithReferences() throws {
        // SP-3 edits-base-plus-3-refs-1024 usage: 95 text, 1792 image in, 196 image out.
        let usage = TokenUsage(inputTextTokens: 95, inputImageTokens: 1792, outputImageTokens: 196)
        let cost = try calculator().actualCost(of: usage, provider: .openai, model: "gpt-image-2.5-sunburst")
        #expect(cost == Decimal(string: "0.020691"))
    }

    private func list(_ rates: [String: Decimal]) -> PriceList {
        PriceList(asOf: "x", entries: [PriceEntry(provider: .openai, model: "m", asOf: "x", perMillionTokens: rates)])
    }

    @Test func cachedTextIsChargedAtCachedRateOnlyForItsShare() {
        // 1M text in, 400k of it cached: 600k at 10 + 400k at 1.
        let usage = TokenUsage(inputTextTokens: 1_000_000, cachedInputTokens: 400_000)
        let cost = CostCalculator(priceList: list(["textIn": 10, "cachedTextIn": 1])).actualCost(of: usage, provider: .openai, model: "m")
        #expect(cost == Decimal(string: "6.4"))
    }

    @Test func cachedOverflowsFromTextToImage() {
        // 100k text + 1M image in, 300k cached: 100k text cached, 200k image cached.
        let usage = TokenUsage(inputTextTokens: 100_000, inputImageTokens: 1_000_000, cachedInputTokens: 300_000)
        let rates: [String: Decimal] = ["textIn": 5, "cachedTextIn": 1, "imageIn": 8, "cachedImageIn": 2]
        let cost = CostCalculator(priceList: list(rates)).actualCost(of: usage, provider: .openai, model: "m")
        // 0.1*1 + 0.8*8 + 0.2*2 = 0.1 + 6.4 + 0.4
        #expect(cost == Decimal(string: "6.9"))
    }

    @Test func cachedFallsBackToFullRatesAndNeverExceedsInput() {
        let usage = TokenUsage(inputTextTokens: 500_000, inputImageTokens: 500_000, cachedInputTokens: 9_000_000)
        let cost = CostCalculator(priceList: list(["textIn": 2, "imageIn": 4])).actualCost(of: usage, provider: .openai, model: "m")
        #expect(cost == 3)
    }

    @Test func cachedRateAppliesWithBundledPrices() throws {
        let full = try calculator().actualCost(of: TokenUsage(inputImageTokens: 1_000_000), provider: .openai, model: "gpt-image-2.5-sunburst")
        let cached = try calculator().actualCost(of: TokenUsage(inputImageTokens: 1_000_000, cachedInputTokens: 1_000_000),
                                                 provider: .openai, model: "gpt-image-2.5-sunburst")
        #expect(cached == 2)
        #expect(try #require(full) > 2)
    }

    @Test func textOutputAndMissingRates() throws {
        let cost = try calculator().actualCost(of: TokenUsage(inputTextTokens: 1_000_000, outputTextTokens: 1_000_000),
                                               provider: .openai, model: "gpt-6-luna")
        #expect(cost == Decimal(string: "0.60"))
        // Image output has no rate on a text model: counts as 0.
        let none = try calculator().actualCost(of: TokenUsage(outputImageTokens: 1000), provider: .openai, model: "gpt-6-luna")
        #expect(none == 0)
    }

    @Test func unknownModelIsNil() throws {
        #expect(try calculator().actualCost(of: TokenUsage(inputTextTokens: 1), provider: .openai, model: "nope") == nil)
        #expect(try calculator().actualCost(of: TokenUsage(inputTextTokens: 1), provider: .gemini, model: "gpt-image-2.5-sunburst") == nil)
    }

    @Test func exposesPriceListDate() throws {
        let list = try PriceList.bundled()
        #expect(CostCalculator(priceList: list).priceListAsOf == list.asOf)
    }
}
