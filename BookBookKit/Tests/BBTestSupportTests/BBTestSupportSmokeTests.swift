import Testing
@testable import BBTestSupport

/// Phase 1b smoke test: the target builds, links and can be imported.
@Test func BBTestSupport_buildsAndLinks() {
    #expect(BBTestSupportModule.name == "BBTestSupport")
}
