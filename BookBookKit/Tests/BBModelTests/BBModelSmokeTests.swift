import Testing
@testable import BBModel

/// Phase 1b smoke test: the target builds, links and can be imported.
@Test func BBModel_buildsAndLinks() {
    #expect(BBModelModule.name == "BBModel")
}
