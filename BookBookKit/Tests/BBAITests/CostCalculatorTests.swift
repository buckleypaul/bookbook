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

    @Test func cachedUsesCachedRateWhenPresent() throws {
        let cost = try calculator().actualCost(of: TokenUsage(cachedInputTokens: 1_000_000), provider: .openai,
                                               model: "gpt-image-2.5-sunburst")
        #expect(cost == 2)
    }

    @Test func cachedFallsBackToImageInRate() throws {
        let list = PriceList(asOf: "x", entries: [
            PriceEntry(provider: .openai, model: "m", asOf: "x", perMillionTokens: ["imageIn": 4])])
        let cost = CostCalculator(priceList: list).actualCost(of: TokenUsage(cachedInputTokens: 500_000), provider: .openai, model: "m")
        #expect(cost == 2)
    }

    @Test func textOutputAndMissingRates() throws {
        let cost = try calculator().actualCost(of: TokenUsage(inputTextTokens: 1_000_000, outputTextTokens: 1_000_000),
                                               provider: .openai, model: "gpt-6-luna")
        #expect(cost == Decimal(string: "11.25"))
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
