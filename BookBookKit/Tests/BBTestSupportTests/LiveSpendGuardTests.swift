import Foundation
import Testing
@testable import BBTestSupport

@Suite struct LiveSpendGuardTests {
    private func tempLog() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "spend-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "live-spend.jsonl")
    }

    @Test func costUsesInlinePrices() {
        let usage = LiveSpendGuard.Usage(inputTextTokens: 1_000_000, inputImageTokens: 1_000_000,
                                         outputTextTokens: 0, outputImageTokens: 1_000_000)
        #expect(abs(LiveSpendGuard.cost(of: usage) - 43) < 1e-9)
    }

    @Test func recordsAndSumsWithoutPromptOrKey() throws {
        let log = tempLog()
        defer { try? FileManager.default.removeItem(at: log.deletingLastPathComponent()) }
        #expect(LiveSpendGuard.totalSpentUSD(logURL: log) == 0)
        let usd = LiveSpendGuard.record(test: "slice_generateLow", provider: "openai", model: "m",
                                        usage: .init(inputTextTokens: 26, outputImageTokens: 196), estimateUSD: 0,
                                        logURL: log)
        LiveSpendGuard.record(test: "t2", provider: "openai", model: "m", usage: nil, estimateUSD: 0.5, logURL: log)
        #expect(abs(LiveSpendGuard.totalSpentUSD(logURL: log) - (usd + 0.5)) < 1e-9)
        let text = try String(contentsOf: log, encoding: .utf8)
        #expect(text.split(separator: "\n").count == 2)
        #expect(!text.contains("prompt"))
    }

    @Test func budgetDefaultsToTen() {
        if ProcessInfo.processInfo.environment["BOOKBOOK_LIVE_BUDGET"] == nil {
            #expect(LiveSpendGuard.budgetUSD == 10)
        }
    }
}
