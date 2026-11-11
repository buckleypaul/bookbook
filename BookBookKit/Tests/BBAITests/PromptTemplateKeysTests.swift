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
                        "request", "legend", "style-references", "cast-entry", "cast-image", "fold", "safe-area"]
        // Every role an image request sends has a legend line (checks use their own prompt).
        let legends = ReferenceRole.allCases.filter { $0 != .checked }.map { "legend-\($0.rawValue)" }
        let assetTypes = ["character", "object", "place"].map { "asset-reference-\($0)" }
        // Text-box decorations (A §7.13).
        let decoration = ["role", "history", "composition", "background-transparent", "background-white",
                          "legend-base"].map { "decoration-\($0)" }
        for key in sections + legends + assetTypes + decoration {
            #expect(PromptTemplates.text(for: key) != nil, "missing Prompts/image-v1/\(key).txt")
        }
    }

    @Test func textPromptsHaveSystemAndUserFiles() {
        for set in ["layout-v1", "consistency-v1", TextStylePrompt.set] {
            for key in ["system", "user"] {
                #expect(exists("\(set)/\(key)"), "missing Prompts/\(set)/\(key).txt")
            }
        }
        #expect(exists("layout-v1/revise"), "missing Prompts/layout-v1/revise.txt")
    }
}
