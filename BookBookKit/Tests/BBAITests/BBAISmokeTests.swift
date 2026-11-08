import Testing
@testable import BBAI

/// Phase 1b smoke test: the target builds, links and can be imported.
@Test func BBAI_buildsAndLinks() {
    #expect(BBAIModule.name == "BBAI")
}
