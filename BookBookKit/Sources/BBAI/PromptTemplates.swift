import Foundation
import Synchronization

/// Versioned prompt text files in `Resources/Prompts/<version>/<key>.txt` with `{{name}}` substitution.
enum PromptTemplates {
    static let version = "image-v1"

    /// Loaded files by `set/key`, misses included. The bundle is read-only, so entries never go stale.
    private static let cache = Mutex<[String: String?]>([:])

    /// The trimmed text of `Prompts/<set>/<key>.txt`, or nil if the file is missing. Cached.
    static func text(for key: String, set: String = version) -> String? {
        let path = "\(set)/\(key)"
        if let cached = cache.withLock({ $0[path] }) { return cached }
        var text: String?
        if let url = Bundle.module.resourceURL?.appendingPathComponent("Prompts/\(path).txt"),
           let contents = try? String(contentsOf: url, encoding: .utf8) {
            text = contents.trimmingCharacters(in: .newlines)
        }
        cache.withLock { $0[path] = .some(text) }
        return text
    }

    /// One left-to-right scan, so substituted text (a name containing `{{name}}`) is never re-expanded.
    static func render(_ template: String, _ values: [String: String]) -> String {
        var out = ""
        var rest = Substring(template)
        while let open = rest.range(of: "{{") {
            out += rest[..<open.lowerBound]
            let afterOpen = rest[open.upperBound...]
            if let close = afterOpen.range(of: "}}"), let value = values[String(afterOpen[..<close.lowerBound])] {
                out += value
                rest = afterOpen[close.upperBound...]
            } else {
                out += "{{"
                rest = afterOpen
            }
        }
        return out + rest
    }

    /// `render` of the file `key` in `set`, or of `fallback` when the file is missing.
    static func render(file key: String, set: String = version, fallback: String, _ values: [String: String]) -> String {
        render(text(for: key, set: set) ?? fallback, values)
    }

    /// A text-model prompt: the user file `key` of `set` rendered and trimmed, and the set's system text.
    static func textPrompt(set: String, user key: String, _ values: [String: String]) -> (system: String, user: String) {
        let user = render(file: key, set: set, fallback: "", values).trimmed
        return (text(for: "system", set: set) ?? "", user)
    }

    /// `object` as pretty-printed JSON with sorted keys, or "{}" if it can't be serialised.
    static func sortedJSON(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    /// One "- item" line per item, or `empty` when there are none.
    static func bulletList(_ items: [String], empty: String = "(none)") -> String {
        items.isEmpty ? empty : items.map { "- \($0)" }.joined(separator: "\n")
    }
}

extension String {
    /// Without leading and trailing whitespace and newlines.
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
