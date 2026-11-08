import BBModel
import Testing
@testable import BBStore

@Suite struct StylePresetsTests {
    @Test func decodeWithUniqueLowercaseHyphenatedIDs() throws {
        let presets = try Presets.stylePresets()
        #expect((6...8).contains(presets.count))
        #expect(Set(presets.map(\.id)).count == presets.count)
        for preset in presets {
            #expect(preset.id == preset.id.lowercased())
            #expect(preset.id.allSatisfy { $0.isLetter || $0 == "-" })
            #expect(!preset.name.isEmpty)
            #expect(!preset.visualDescription.isEmpty)
            #expect(preset.negativeGuidance == nil)
        }
        let ids = Set(presets.map(\.id))
        for expected in ["watercolour", "crayon", "cut-paper", "gouache", "ink-and-wash", "coloured-pencil"] {
            #expect(ids.contains(expected))
        }
    }
}
