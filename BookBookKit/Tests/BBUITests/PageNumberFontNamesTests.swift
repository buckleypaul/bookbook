import AppKit
import Testing
@testable import BBUI

@Suite struct PageNumberFontNamesTests {
    @Test func familyRoundTripsThroughPostScriptName() throws {
        let ps = try #require(PageNumberFontNames.postScriptName(forFamily: "Helvetica"))
        #expect(ps == "Helvetica")
        #expect(PageNumberFontNames.family(forPostScriptName: ps) == "Helvetica")
    }

    @Test func missingFontsAreNil() {
        #expect(PageNumberFontNames.postScriptName(forFamily: "No Such Family 123") == nil)
        #expect(PageNumberFontNames.family(forPostScriptName: "NoSuchFont-123") == nil)
    }
}
