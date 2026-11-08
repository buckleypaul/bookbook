import Testing
@testable import BBOpenAI

/// Phase 1b smoke test: the target builds, links and can be imported.
@Test func BBOpenAI_buildsAndLinks() {
    #expect(BBOpenAIModule.name == "BBOpenAI")
}
