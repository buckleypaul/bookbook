import AppKit
import Testing
@testable import BBUI

@Suite struct PageNumberFontNamesTests {
    @MainActor @Test func familyRoundTripsThroughPostScriptName() throws {
        let ps = try #require(PageNumberFontNames.postScriptName(forFamily: "Helvetica"))
        #expect(ps == "Helvetica")
        #expect(FontFamilies.family(of: ps) == "Helvetica")
    }

    @MainActor @Test func missingFontsAreNil() {
        #expect(PageNumberFontNames.postScriptName(forFamily: "No Such Family 123") == nil)
        #expect(FontFamilies.family(of: "NoSuchFont-123") == nil)
    }
}
