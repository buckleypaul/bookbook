import Foundation

/// Words that often trigger provider safety filters (A §7.11 rule 2), loaded from the bundled
/// `SensitiveTerms.json`. Matching is whole-word and case-insensitive.
public struct SensitiveTerms: Sendable {
    public struct Entry: Hashable, Codable, Sendable {
        public var term: String
        public var forms: [String]
        public init(term: String, forms: [String] = []) {
            self.term = term
            self.forms = forms
        }
        enum CodingKeys: String, CodingKey { case term, forms }
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            term = try c.decode(String.self, forKey: .term)
            forms = try c.decodeIfPresent([String].self, forKey: .forms) ?? []
        }
    }

    public private(set) var entries: [Entry]
    /// Per entry, the whole-word matcher for the term and each form (compiled once).
    private let patterns: [(term: String, regexes: [NSRegularExpression])]

    public init(entries: [Entry]) {
        self.entries = entries
        patterns = entries.map { entry in
            let regexes = ([entry.term] + entry.forms).filter { !$0.isEmpty }.compactMap { word in
                let pattern = "(?<![\\p{L}\\p{N}_])" + NSRegularExpression.escapedPattern(for: word) + "(?![\\p{L}\\p{N}_])"
                return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            }
            return (entry.term, regexes)
        }
    }

    private struct File: Decodable { var terms: [Entry] }

    public init(data: Data) throws {
        self.init(entries: try JSONDecoder().decode(File.self, from: data).terms)
    }

    /// The bundled list; empty if the resource is missing or unreadable.
    public static let bundled: SensitiveTerms = {
        guard let url = Bundle.module.url(forResource: "SensitiveTerms", withExtension: "json"),
              let data = try? Data(contentsOf: url), let terms = try? SensitiveTerms(data: data)
        else { return SensitiveTerms(entries: []) }
        return terms
    }()

    /// Canonical terms found in `text` (whole word, case-insensitive, including `forms`),
    /// in order of first appearance.
    public func matches(in text: String) -> [String] {
        var found: [(position: Int, term: String)] = []
        let range = NSRange(text.startIndex..., in: text)
        for (term, regexes) in patterns {
            var best: Int?
            for regex in regexes {
                guard let match = regex.firstMatch(in: text, range: range) else { continue }
                best = min(best ?? Int.max, match.range.location)
            }
            if let best { found.append((best, term)) }
        }
        return found.sorted { $0.position < $1.position }.map(\.term)
    }
}
