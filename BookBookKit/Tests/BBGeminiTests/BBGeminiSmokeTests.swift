import Testing
@testable import BBGemini

/// Phase 1b smoke test: the target builds, links and can be imported.
@Test func BBGemini_buildsAndLinks() {
    #expect(BBGeminiModule.name == "BBGemini")
}
