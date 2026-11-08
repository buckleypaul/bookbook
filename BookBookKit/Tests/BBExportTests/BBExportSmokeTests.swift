import Testing
@testable import BBExport

/// Phase 1b smoke test: the target builds, links and can be imported.
@Test func BBExport_buildsAndLinks() {
    #expect(BBExportModule.name == "BBExport")
}
