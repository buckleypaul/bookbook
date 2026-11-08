import Foundation

/// Spend log and budget guard for live provider tests (implementation-plan.md §2.2, §2.4).
///
/// Appends one JSON line per live call to `~/Library/Caches/BookBook-dev/live-spend.jsonl`
/// (override the folder with `BOOKBOOK_SPEND_LOG_DIR`): `{at, test, provider, model, usd, basis}`.
/// Never any key or prompt text. Live tests skip once the running total reaches
/// `BOOKBOOK_LIVE_BUDGET` (default 10 USD).
///
/// BBTestSupport depends on nothing, so prices are an inline table (per million tokens), not
/// `PriceList.json`. It only has to be good enough to track spend against the cap.
public enum LiveSpendGuard {
    /// Usage in the shape providers report it.
    public struct Usage: Sendable, Equatable {
        public var inputTextTokens: Int
        public var inputImageTokens: Int
        public var outputTextTokens: Int
        public var outputImageTokens: Int

        public init(inputTextTokens: Int = 0, inputImageTokens: Int = 0,
                    outputTextTokens: Int = 0, outputImageTokens: Int = 0) {
            self.inputTextTokens = inputTextTokens
            self.inputImageTokens = inputImageTokens
            self.outputTextTokens = outputTextTokens
            self.outputImageTokens = outputImageTokens
        }
    }

    /// USD per million tokens for `gpt-image-2.5-sunburst`; used for every model, as a safe estimate.
    static let textIn = 5.0, imageIn = 8.0, textOut = 10.0, imageOut = 30.0

    public static func cost(of usage: Usage) -> Double {
        (Double(usage.inputTextTokens) * textIn + Double(usage.inputImageTokens) * imageIn
            + Double(usage.outputTextTokens) * textOut + Double(usage.outputImageTokens) * imageOut) / 1_000_000
    }

    /// `BOOKBOOK_LIVE_BUDGET`, default 10.
    public static var budgetUSD: Double {
        if let raw = ProcessInfo.processInfo.environment["BOOKBOOK_LIVE_BUDGET"],
           let value = Double(raw.trimmingCharacters(in: .whitespaces)), value.isFinite, value >= 0 { return value }
        return 10
    }

    /// Sum of `usd` over the log (0 if there is none).
    public static func totalSpentUSD() -> Double { totalSpentUSD(logURL: defaultLogURL()) }

    /// True while the running total is below the budget. Use in the live test's skip condition.
    public static func isUnderBudget() -> Bool { totalSpentUSD() < budgetUSD }

    /// Records one call, priced from `usage` (or `estimateUSD` when there is none). Returns the USD recorded.
    @discardableResult
    public static func record(test: String, provider: String, model: String, usage: Usage?,
                              estimateUSD: Double = 0) -> Double {
        record(test: test, provider: provider, model: model, usage: usage, estimateUSD: estimateUSD,
               logURL: defaultLogURL())
    }

    // MARK: Seams for offline tests

    private struct Entry: Codable {
        var at: String
        var test: String
        var provider: String
        var model: String
        var usd: Double
        var basis: String
    }

    private struct UsdOnly: Decodable { var usd: Double }

    private static let lock = NSLock()

    static func defaultLogURL() -> URL {
        let directory: URL
        if let override = ProcessInfo.processInfo.environment["BOOKBOOK_SPEND_LOG_DIR"], !override.isEmpty {
            directory = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            directory = FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Library/Caches/BookBook-dev", directoryHint: .isDirectory)
        }
        return directory.appending(path: "live-spend.jsonl", directoryHint: .notDirectory)
    }

    static func totalSpentUSD(logURL: URL) -> Double {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: logURL) else { return 0 }
        let decoder = JSONDecoder()
        var total = 0.0
        for line in data.split(separator: UInt8(ascii: "\n")) {
            if let entry = try? decoder.decode(UsdOnly.self, from: Data(line)), entry.usd.isFinite { total += entry.usd }
        }
        return total
    }

    @discardableResult
    static func record(test: String, provider: String, model: String, usage: Usage?,
                       estimateUSD: Double, logURL: URL) -> Double {
        let usd: Double, basis: String
        if let usage {
            usd = cost(of: usage); basis = "usage"
        } else {
            usd = estimateUSD; basis = estimateUSD == 0 ? "zero" : "estimate"
        }
        let entry = Entry(at: ISO8601DateFormatter().string(from: Date()), test: test, provider: provider,
                          model: model, usd: usd, basis: basis)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard var line = try? encoder.encode(entry) else { return usd }
        line.append(UInt8(ascii: "\n"))
        lock.lock(); defer { lock.unlock() }
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: logURL.path) { fileManager.createFile(atPath: logURL.path, contents: nil) }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        }
        return usd
    }
}
