import Foundation

// Spend log internals. The functions taking a log URL are the seams offline tests use.
extension LiveSpendGuard {
    private struct Entry: Codable {
        var at: String
        var spike: String
        var provider: Provider
        var model: String
        var usd: Double
        var basis: String
        var usage: Usage?
    }
    private struct UsdOnly: Decodable { var usd: Double }

    private static let lock = NSLock()

    static func defaultLogURL() -> URL {
        let dir: URL
        if let o = ProcessInfo.processInfo.environment["BOOKBOOK_SPEND_LOG_DIR"], !o.isEmpty {
            dir = URL(fileURLWithPath: o, isDirectory: true)
        } else {
            dir = FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Library/Caches/BookBook-dev", directoryHint: .isDirectory)
        }
        return dir.appending(path: "live-spend.jsonl", directoryHint: .notDirectory)
    }

    static func totalSpentUSD(logURL: URL) -> Double {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: logURL) else { return 0 }
        let decoder = JSONDecoder()
        var total = 0.0
        for line in data.split(separator: UInt8(ascii: "\n")) {
            if let e = try? decoder.decode(UsdOnly.self, from: Data(line)), e.usd.isFinite { total += e.usd }
        }
        return total
    }

    static func isUnderBudget(logURL: URL, budget: Double) -> Bool { totalSpentUSD(logURL: logURL) < budget }

    @discardableResult
    static func record(spike: String, provider: Provider, model: String, usage: Usage?,
                       estimateUSD: Double, logURL: URL) -> Double {
        let usd: Double, basis: String
        if let usage {
            usd = SpikePrice.forModel(model).cost(of: usage); basis = "usage"
        } else {
            usd = estimateUSD; basis = estimateUSD == 0 ? "zero" : "estimate"
        }
        let entry = Entry(at: ISO8601DateFormatter().string(from: Date()), spike: spike, provider: provider,
                          model: model, usd: usd, basis: basis, usage: usage)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard var line = try? encoder.encode(entry) else { return usd }
        line.append(UInt8(ascii: "\n"))
        lock.lock(); defer { lock.unlock() }
        let fm = FileManager.default
        try? fm.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: logURL.path) { fm.createFile(atPath: logURL.path, contents: nil) }
        if let h = try? FileHandle(forWritingTo: logURL) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: line)
        }
        return usd
    }
}
