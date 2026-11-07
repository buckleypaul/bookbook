import Foundation

extension FixtureRecorder {
    /// `Spikes/Fixtures`, found by walking up from this file: Spikes/Sources/SpikeKit/Recorder.swift.
    static func defaultRoot(file: String = #filePath) -> URL {
        URL(fileURLWithPath: file)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Fixtures", directoryHint: .isDirectory)
    }

    private static let secretPatterns: [NSRegularExpression] = [
        "sk-[A-Za-z0-9_-]{20,}", "AIza[0-9A-Za-z_-]{35}",
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    private static let idReplacements: [(NSRegularExpression, String)] = [
        (maskedKeyPattern, "sk-REDACTED"),
        ("org-[A-Za-z0-9]{6,}", "org-PLACEHOLDER"), ("proj_[A-Za-z0-9]{6,}", "proj_PLACEHOLDER"),
    ].compactMap { pattern, template in
        (try? NSRegularExpression(pattern: pattern)).map { ($0, template) }
    }

    func write(_ response: HTTPResponse, name: String, keepRealImage: Bool) throws(FixtureRecorderError) {
        guard !name.isEmpty, !name.contains("/"), !name.contains("..") else {
            throw .writeFailed(file: name)
        }
        let dir = root.appending(path: provider.rawValue, directoryHint: .isDirectory)
            .appending(path: spike, directoryHint: .isDirectory)
        let bodyName = "\(name).json", metaName = "\(name).meta.json"

        // The raw body must never contain the key either (before any transformation).
        if key.occurs(in: response.body) { throw .containsKey(file: bodyName) }

        let body = Self.transform(response.body, keepRealImage: keepRealImage)

        let headers = response.headers.reduce(into: [String: String]()) { out, kv in
            let lower = kv.key.lowercased()
            if Self.isAllowedHeader(lower) { out[lower] = kv.value }
        }
        let comps = response.duration.components
        let durationMs = Int(comps.seconds) * 1000 + Int(comps.attoseconds / 1_000_000_000_000_000)
        let metaObject: [String: Any] = ["status": response.status, "durationMs": durationMs, "headers": headers]
        guard let metaData = try? JSONSerialization.data(
            withJSONObject: metaObject, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else {
            throw .writeFailed(file: metaName)
        }

        for (file, bytes) in [(bodyName, body), (metaName, metaData)] {
            if key.occurs(in: bytes) || Self.matchesSecretPattern(bytes) { throw .containsKey(file: file) }
        }

        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch { throw .writeFailed(file: bodyName) }
        do { try body.write(to: dir.appending(path: bodyName), options: .atomic) } catch { throw .writeFailed(file: bodyName) }
        do { try metaData.write(to: dir.appending(path: metaName), options: .atomic) } catch { throw .writeFailed(file: metaName) }
    }

    static func matchesSecretPattern(_ data: Data) -> Bool {
        let text = String(decoding: data, as: UTF8.self)
        let range = NSRange(text.startIndex..., in: text)
        return secretPatterns.contains { $0.firstMatch(in: text, range: range) != nil }
    }

    static func transform(_ body: Data, keepRealImage: Bool) -> Data {
        var out = body
        if let object = try? JSONSerialization.jsonObject(with: body, options: []),
           object is [String: Any] || object is [Any] {
            let replaced = keepRealImage ? object : replaceImages(object)
            if let pretty = try? JSONSerialization.data(
                withJSONObject: replaced, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
                out = pretty
            }
        }
        guard var text = String(data: out, encoding: .utf8) else { return out }
        for (regex, template) in idReplacements {
            text = regex.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
        }
        return Data(text.utf8)
    }

    private static func replaceImages(_ node: Any, parentKey: String? = nil) -> Any {
        let placeholder = TestImages.placeholder().base64EncodedString()
        if let dict = node as? [String: Any] {
            var result: [String: Any] = [:]
            for (k, v) in dict {
                if k == "b64_json", v is String {
                    result[k] = placeholder
                } else if k == "data", v is String, parentKey == "inlineData" || parentKey == "inline_data" {
                    result[k] = placeholder
                } else {
                    result[k] = replaceImages(v, parentKey: k)
                }
            }
            return result
        }
        if let array = node as? [Any] { return array.map { replaceImages($0, parentKey: parentKey) } }
        return node
    }
}
