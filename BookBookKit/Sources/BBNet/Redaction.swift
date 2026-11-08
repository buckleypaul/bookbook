import Foundation

// Owned by the Net+OpenAI lane. Seeded from Spikes/Sources/SpikeKit (Phase 0).

extension Redaction {
    /// Header names whose values are never shown (any case).
    public static let secretHeaderNames: Set<String> = ["authorization", "x-goog-api-key"]

    /// A masked key echo: any key-ish prefix, four or more asterisks, then the visible suffix.
    /// Matches `sk-proj-****abcd` and also keys without the `sk-` prefix (SP-5 echoed `bookbook****-key`).
    static let maskedKeyPattern = #"[A-Za-z0-9_-]*\*{4,}[A-Za-z0-9_-]{0,8}"#

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
        text.replacingOccurrences(of: maskedKeyPattern, with: "sk-REDACTED", options: .regularExpression)
    }
}
