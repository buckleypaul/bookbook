import Testing
@testable import BBLayout

/// Phase 1b smoke test: the target builds, links and can be imported.
@Test func BBLayout_buildsAndLinks() {
    #expect(BBLayoutModule.name == "BBLayout")
}
