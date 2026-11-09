import BBAICore
import BBModel
import Foundation

// Phase 12. A §7.8.

public struct ConsistencyAssetContext: Hashable, Sendable {
    public var name: String
    public var description: String

    public init(name: String, description: String) {
        self.name = name
        self.description = description
    }
}

public enum ConsistencyPrompt {
    static let set = "consistency-v1"

    /// The system and user text for a check. `imageLabels` are the labels of the checked image
    /// and references in send order, so the text can refer to them.
    public static func instructions(assets: [ConsistencyAssetContext], styleDescription: String,
                                    imageLabels: [String]) -> (system: String, user: String) {
        var images = ""
        if let first = imageLabels.first {
            images = "Image 1 (\(first)) is the new illustration to check."
            let refs = imageLabels.dropFirst().enumerated().map { "Image \($0.offset + 2): \($0.element)" }
            images += refs.isEmpty ? " No references are attached." : " The other images are references:\n" + refs.joined(separator: "\n")
        }
        let assetLines = assets.isEmpty
            ? "(none)"
            : assets.map { asset in
                let detail = asset.description.trimmingCharacters(in: .whitespacesAndNewlines)
                return detail.isEmpty ? "- \(asset.name)" : "- \(asset.name): \(detail)"
            }.joined(separator: "\n")
        let style = styleDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = PromptTemplates.render(PromptTemplates.text(for: "user", set: set) ?? "", [
            "images": images,
            "assets": assetLines,
            "style": style.isEmpty ? "(not described)" : style,
        ]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (PromptTemplates.text(for: "system", set: set) ?? "", user)
    }

    /// The one-click fix message (A §7.8): "Keep everything the same, but: make Pip's scarf red
    /// as in the reference; …". Major differences first.
    public static func correctionMessage(_ differences: [ConsistencyDifference]) -> String {
        let ordered = differences.filter { $0.severity == .major } + differences.filter { $0.severity != .major }
        let clauses = ordered.compactMap(clause)
        guard !clauses.isEmpty else { return "" }
        return "Keep everything the same, but: " + clauses.joined(separator: "; ")
    }

    private static func clause(_ difference: ConsistencyDifference) -> String? {
        let name = difference.asset?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let aspect = difference.aspect.trimmingCharacters(in: .whitespacesAndNewlines)
        let expected = difference.expected.trimmingCharacters(in: .whitespacesAndNewlines)
        let subject: String
        if name.isEmpty {
            subject = aspect.isEmpty ? "" : "the \(aspect)"
        } else {
            let possessive = name.hasSuffix("s") ? "\(name)'" : "\(name)'s"
            subject = aspect.isEmpty ? name : "\(possessive) \(aspect)"
        }
        switch (subject.isEmpty, expected.isEmpty) {
        case (true, true): return nil
        case (true, false): return "make it \(expected) as in the reference"
        case (false, true): return "match the reference for \(subject)"
        case (false, false): return "make \(subject) \(expected) as in the reference"
        }
    }
}
