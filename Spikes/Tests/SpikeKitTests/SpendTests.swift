import Foundation
import Testing
@testable import SpikeKit

@Suite struct UsageTests {
    @Test func imagesAPIBody() {
        let body = """
        {"data":[{"b64_json":"x"}],"usage":{"input_tokens":100,"output_tokens":400,
        "input_tokens_details":{"text_tokens":60,"image_tokens":40,"cached_tokens":10},
        "output_tokens_details":{"text_tokens":0,"image_tokens":400}}}
        """
        #expect(Usage.openAI(from: Data(body.utf8)) == Usage(inputTextTokens: 60, inputImageTokens: 40, cachedInputTokens: 10, outputTextTokens: 0, outputImageTokens: 400))
    }

    @Test func imagesAPIWithoutOutputDetails() {
        let body = #"{"usage":{"input_tokens":10,"output_tokens":272}}"#
        #expect(Usage.openAI(from: Data(body.utf8)) == Usage(inputTextTokens: 10, outputImageTokens: 272))
    }

    @Test func chatCompletionsBody() {
        let body = """
        {"choices":[],"usage":{"prompt_tokens":50,"completion_tokens":20,"total_tokens":70,
        "prompt_tokens_details":{"cached_tokens":8}}}
        """
        #expect(Usage.openAI(from: Data(body.utf8)) == Usage(inputTextTokens: 50, cachedInputTokens: 8, outputTextTokens: 20))
    }

    @Test func noUsageIsNil() {
        #expect(Usage.openAI(from: Data(#"{"error":{}}"#.utf8)) == nil)
        #expect(Usage.openAI(from: Data("garbage".utf8)) == nil)
    }
}

@Suite struct PriceTests {
    @Test func modelRows() {
        let image = SpikePrice(textIn: 5, imageIn: 8, cachedIn: 2, textOut: 10, imageOut: 30)
        #expect(SpikePrice.forModel("gpt-image-2.5-sunburst") == image)
        #expect(SpikePrice.forModel("gpt-image-2") == image)
        #expect(SpikePrice.forModel("some-new-image-model") == image)
        #expect(SpikePrice.forModel("gpt-6-luna") == SpikePrice(textIn: 1.25, imageIn: 1.25, cachedIn: 0.125, textOut: 10, imageOut: 0))
        #expect(SpikePrice.forModel("gpt-6.1-terra") == SpikePrice(textIn: 2.5, imageIn: 2.5, cachedIn: 0.25, textOut: 15, imageOut: 0))
        #expect(SpikePrice.forModel("mystery") == SpikePrice.forModel("gpt-6-luna"))
    }

    @Test func imageOutputCost() {
        let c = SpikePrice.forModel("gpt-image-2.5-sunburst").cost(of: Usage(inputTextTokens: 100, outputImageTokens: 200))
        #expect(abs(c - (100 * 5 + 200 * 30) / 1_000_000) < 1e-12)
    }

    @Test func cachedIsSubsetOfInput() {
        let p = SpikePrice.forModel("gpt-image-2.5-sunburst")
        let c = p.cost(of: Usage(inputTextTokens: 100, inputImageTokens: 50, cachedInputTokens: 30))
        #expect(abs(c - (30 * 2 + 70 * 5 + 50 * 8) / 1_000_000) < 1e-12)
        // Cached spills into image tokens once text is used up.
        let c2 = p.cost(of: Usage(inputTextTokens: 10, inputImageTokens: 50, cachedInputTokens: 30))
        #expect(abs(c2 - (30 * 2 + 0 * 5 + 30 * 8) / 1_000_000) < 1e-12)
        // Cached beyond the input is capped, never negative.
        let c3 = p.cost(of: Usage(inputTextTokens: 10, cachedInputTokens: 999))
        #expect(abs(c3 - 10 * 2 / 1_000_000) < 1e-12)
    }
}

@Suite struct SpendGuardTests {
    @Test func recordAndTotal() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appending(path: "nested/live-spend.jsonl")
        #expect(LiveSpendGuard.totalSpentUSD(logURL: log) == 0)

        let usage = Usage(inputTextTokens: 100, outputImageTokens: 200)
        let a = LiveSpendGuard.record(spike: "SP2_x", provider: .openai, model: "gpt-image-2.5-sunburst", usage: usage, estimateUSD: 99, logURL: log)
        let b = LiveSpendGuard.record(spike: "SP2_y", provider: .openai, model: "gpt-image-2", usage: nil, estimateUSD: 0.01, logURL: log)
        let c = LiveSpendGuard.record(spike: "SP5_z", provider: .openai, model: "gpt-image-2", usage: nil, estimateUSD: 0, logURL: log)
        #expect(abs(a - 0.0065) < 1e-9)
        #expect(b == 0.01)
        #expect(c == 0)
        #expect(abs(LiveSpendGuard.totalSpentUSD(logURL: log) - 0.0165) < 1e-9)

        let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 3)
        var objs: [[String: Any]] = []
        for line in lines {
            let o = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            objs.append(o)
        }
        #expect(objs.map { $0["basis"] as? String } == ["usage", "estimate", "zero"])
        #expect(objs[0]["spike"] as? String == "SP2_x")
        #expect(objs[0]["provider"] as? String == "openai")
        #expect(objs[0]["model"] as? String == "gpt-image-2.5-sunburst")
        #expect(objs[0]["usage"] != nil)
        #expect(objs[1]["usage"] == nil)
        let at = try #require(objs[0]["at"] as? String)
        #expect(ISO8601DateFormatter().date(from: at) != nil)
    }

    @Test func budget() {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appending(path: "l.jsonl")
        #expect(LiveSpendGuard.isUnderBudget(logURL: log, budget: 1))
        LiveSpendGuard.record(spike: "s", provider: .openai, model: "gpt-image-2", usage: nil, estimateUSD: 0.5, logURL: log)
        #expect(LiveSpendGuard.isUnderBudget(logURL: log, budget: 1))
        LiveSpendGuard.record(spike: "s", provider: .openai, model: "gpt-image-2", usage: nil, estimateUSD: 0.5, logURL: log)
        #expect(!LiveSpendGuard.isUnderBudget(logURL: log, budget: 1))
        #expect(LiveSpendGuard.budgetUSD >= 0)
        #expect(LiveSpendError.overBudget(spentUSD: 1, budgetUSD: 1).description.contains("budget"))
    }

    @Test func corruptLinesAreSkipped() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appending(path: "l.jsonl")
        try Data("not json\n{\"usd\":0.25}\n{\"usd\":\n\n{\"usd\":0.5}\n".utf8).write(to: log)
        #expect(abs(LiveSpendGuard.totalSpentUSD(logURL: log) - 0.75) < 1e-12)
    }
}
