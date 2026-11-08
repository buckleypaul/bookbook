import Testing
@testable import BBStore

/// Phase 1b smoke test: the target builds, links and can be imported.
@Test func BBStore_buildsAndLinks() {
    #expect(BBStoreModule.name == "BBStore")
}
