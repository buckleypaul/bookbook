import Testing
@testable import BBNet

/// Phase 1b smoke test: the target builds, links and can be imported.
@Test func BBNet_buildsAndLinks() {
    #expect(BBNetModule.name == "BBNet")
}
