import Testing
@testable import BBUI

/// Phase 1b smoke test: the target builds, links and can be imported.
@Test func BBUI_buildsAndLinks() {
    #expect(BBUIModule.name == "BBUI")
}
