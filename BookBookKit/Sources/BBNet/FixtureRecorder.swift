import CoreGraphics
import Foundation
import ImageIO

public enum FixtureRecorderError: Error, Sendable, CustomStringConvertible {
    case containsKey(file: String)
    case writeFailed(file: String)

    public var description: String {
        switch self {
        case .containsKey(let file): "refusing to write \(file): content contains an API key or secret-shaped string"
        case .writeFailed(let file): "could not write fixture \(file)"
        }
    }
}

/// Writes `<name>.json` (response body) and `<name>.meta.json` (`{status, durationMs, headers}`) under
/// `directory`, but only when `recording` is on (`BOOKBOOK_RECORD_FIXTURES=1`); otherwise it does nothing.
///
/// Transformations: base64 images (`data[].b64_json`, `inlineData.data`) become a 64 px placeholder PNG
/// unless `keepRealImage`; masked-key echoes become `sk-REDACTED`; `org-…` / `proj_…` IDs become
/// placeholders. Only allow-listed response headers are kept; request headers are never seen.
/// Before writing, each file's bytes are checked in memory with `containsSecret` and the secret-scan
/// patterns; on a match nothing is written and it throws.
public struct FixtureRecorder: Sendable {
    /// Same variable `scripts/record-fixtures.sh` sets.
    public static let recordVariable = "BOOKBOOK_RECORD_FIXTURES"

    public static var isRecordingEnabled: Bool { ProcessInfo.processInfo.environment[recordVariable] == "1" }

    /// content-type, retry-after, x-request-id and every x-ratelimit-* header.
    public static func isAllowedHeader(_ lowercasedName: String) -> Bool {
        ["content-type", "retry-after", "x-request-id"].contains(lowercasedName)
            || lowercasedName.hasPrefix("x-ratelimit-")
    }

    private let directory: URL
    private let containsSecret: @Sendable (Data) -> Bool
    private let recording: Bool

    /// - Parameters:
    ///   - directory: where `<name>.json` / `<name>.meta.json` go.
    ///   - containsSecret: true if the bytes contain the API key (pass `APIKey.occurs(in:)`).
    ///   - recording: defaults to the `BOOKBOOK_RECORD_FIXTURES` environment variable.
    public init(directory: URL, containsSecret: @escaping @Sendable (Data) -> Bool,
                recording: Bool = FixtureRecorder.isRecordingEnabled) {
        self.directory = directory
        self.containsSecret = containsSecret
        self.recording = recording
    }

    public func record(_ response: HTTPResponse, name: String, keepRealImage: Bool = false) throws(FixtureRecorderError) {
        guard recording else { return }
        try write(response, name: name, keepRealImage: keepRealImage)
    }

    // MARK: Internals

    private static let secretPatterns: [NSRegularExpression] = [
        "sk-[A-Za-z0-9_-]{20,}", "AIza[0-9A-Za-z_-]{35}",
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    private static let replacements: [(NSRegularExpression, String)] = [
        (Redaction.maskedKeyPattern, "sk-REDACTED"),
        ("org-[A-Za-z0-9]{6,}", "org-PLACEHOLDER"), ("proj_[A-Za-z0-9]{6,}", "proj_PLACEHOLDER"),
    ].compactMap { pattern, template in
        (try? NSRegularExpression(pattern: pattern)).map { ($0, template) }
    }

    func write(_ response: HTTPResponse, name: String, keepRealImage: Bool) throws(FixtureRecorderError) {
        guard !name.isEmpty, !name.contains("/"), !name.contains("..") else { throw .writeFailed(file: name) }
        let bodyName = "\(name).json", metaName = "\(name).meta.json"

        // The raw body must never contain the key (checked before any transformation).
        if containsSecret(response.body) { throw .containsKey(file: bodyName) }
        let body = Self.transform(response.body, keepRealImage: keepRealImage)

        var headers: [String: String] = [:]
        for (key, value) in response.headers where Self.isAllowedHeader(key.lowercased()) {
            headers[key.lowercased()] = value
        }
        let parts = response.duration.components
        let durationMs = Int(parts.seconds) * 1000 + Int(parts.attoseconds / 1_000_000_000_000_000)
        let meta: [String: Any] = ["status": response.status, "durationMs": durationMs, "headers": headers]
        guard let metaData = try? JSONSerialization.data(
            withJSONObject: meta, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else {
            throw .writeFailed(file: metaName)
        }

        for (file, bytes) in [(bodyName, body), (metaName, metaData)] {
            if containsSecret(bytes) || Self.matchesSecretPattern(bytes) { throw .containsKey(file: file) }
        }

        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { throw .writeFailed(file: bodyName) }
        do { try body.write(to: directory.appending(path: bodyName), options: .atomic) }
        catch { throw .writeFailed(file: bodyName) }
        do { try metaData.write(to: directory.appending(path: metaName), options: .atomic) }
        catch { throw .writeFailed(file: metaName) }
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
            let replaced = keepRealImage ? object : replaceImages(object, placeholder: placeholderBase64)
            if let pretty = try? JSONSerialization.data(
                withJSONObject: replaced, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
                out = pretty
            }
        }
        guard var text = String(data: out, encoding: .utf8) else { return out }
        for (regex, template) in replacements {
            text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                                  withTemplate: template)
        }
        return Data(text.utf8)
    }

    private static func replaceImages(_ node: Any, parentKey: String? = nil, placeholder: String) -> Any {
        if let dict = node as? [String: Any] {
            var result: [String: Any] = [:]
            for (key, value) in dict {
                if key == "b64_json", value is String {
                    result[key] = placeholder
                } else if key == "data", value is String, parentKey == "inlineData" || parentKey == "inline_data" {
                    result[key] = placeholder
                } else {
                    result[key] = replaceImages(value, parentKey: key, placeholder: placeholder)
                }
            }
            return result
        }
        if let array = node as? [Any] {
            return array.map { replaceImages($0, parentKey: parentKey, placeholder: placeholder) }
        }
        return node
    }

    /// A 64x64 grey-quadrant PNG, base64 encoded.
    static let placeholderBase64: String = placeholderPNG().base64EncodedString()

    static func placeholderPNG() -> Data {
        let size = 64
        var pixels = [UInt8](repeating: 255, count: size * size * 4)
        let greys: [UInt8] = [200, 150, 100, 50]
        for y in 0..<size {
            for x in 0..<size {
                let grey = greys[(y < size / 2 ? 0 : 2) + (x < size / 2 ? 0 : 1)]
                let i = (y * size + x) * 4
                pixels[i] = grey; pixels[i + 1] = grey; pixels[i + 2] = grey
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: size * 4, space: space,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return Data() }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else { return Data() }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? out as Data : Data()
    }
}
