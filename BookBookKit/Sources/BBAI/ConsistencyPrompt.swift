import BBAICore
import BBModel
import Foundation

// Phase 12 contract (main thread); body filled by the BBAI lane. A §7.8.

public struct ConsistencyAssetContext: Hashable, Sendable {
    public var name: String
    public var description: String

    public init(name: String, description: String) {
        self.name = name
        self.description = description
    }
}

public enum ConsistencyPrompt {
    /// The system and user text for a check. `imageLabels` are the labels of the checked image
    /// and references in send order, so the text can refer to them.
    public static func instructions(assets: [ConsistencyAssetContext], styleDescription: String,
                                    imageLabels: [String]) -> (system: String, user: String) {
        fatalError("Phase 12: ConsistencyPrompt not implemented")
    }

    /// The one-click fix message (A §7.8): "Keep everything the same, but: make Pip's scarf red
    /// as in the reference; …". Major differences first.
    public static func correctionMessage(_ differences: [ConsistencyDifference]) -> String {
        fatalError("Phase 12: ConsistencyPrompt not implemented")
    }
}
