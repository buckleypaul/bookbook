import Testing
@testable import BBAICore

/// Phase 1b smoke test: the target builds, links and can be imported.
@Test func BBAICore_buildsAndLinks() {
    #expect(BBAICoreModule.name == "BBAICore")
}
