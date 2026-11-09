import Foundation
import Testing
@testable import BBAI

/// A missing prompt file falls back silently to a terse default, so check every key the code uses.
@Suite struct PromptTemplateKeysTests {
    private func exists(_ path: String) -> Bool {
        guard let base = Bundle.module.resourceURL else { return false }
        return FileManager.default.fileExists(atPath: base.appendingPathComponent("Prompts/\(path).txt").path)
    }

    @Test func everyImagePromptKeyHasAFile() {
        let sections = ["role", "style", "avoid", "cast", "subject", "composition", "story", "history", "region",
                        "request", "legend", "style-references", "cast-entry", "cast-image", "fold", "safe-area",
                        "asset-same", "sheet-expression", "asset-reference-slot"]
        let legends = ["base", "reference", "asset", "style"].map { "legend-\($0)" }
        let assetTypes = ["character", "object", "place"].map { "asset-reference-\($0)" }
        let views = ["front", "side", "back", "threeQuarter"].map { "sheet-view-\($0)" }
        for key in sections + legends + assetTypes + views {
            #expect(PromptTemplates.text(for: key) != nil, "missing Prompts/image-v1/\(key).txt")
        }
    }

    @Test func textPromptsHaveSystemAndUserFiles() {
        for set in ["layout-v1", "consistency-v1"] {
            for key in ["system", "user"] {
                #expect(exists("\(set)/\(key)"), "missing Prompts/\(set)/\(key).txt")
            }
        }
    }
}
