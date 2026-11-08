import Foundation

// Owned by the Net+OpenAI lane. Seeded from Spikes/Sources/SpikeKit (Phase 0).

extension Redaction {
    /// Header names whose values are never shown (any case).
    public static let secretHeaderNames: Set<String> = ["authorization", "x-goog-api-key"]

    /// A copy with secret headers replaced by `<redacted>`.
    public static func redactedHeaders(_ headers: [String: String]) -> [String: String] {
        var out = headers
        for name in headers.keys where secretHeaderNames.contains(name.lowercased()) {
            out[name] = "<redacted>"
        }
        return out
    }

    /// OpenAI echoes a masked key in 401 bodies (`sk-proj-****…abcd`). Replaces such echoes
    /// with `sk-REDACTED` so not even the visible suffix is stored or shown.
    public static func redactMaskedKeys(_ text: String) -> String {
        text.replacingOccurrences(of: #"sk-[A-Za-z0-9_-]*\*{4,}[A-Za-z0-9_-]{0,8}"#, with: "sk-REDACTED",
                                  options: .regularExpression)
    }
}
