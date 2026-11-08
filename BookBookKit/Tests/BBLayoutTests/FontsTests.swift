import BBModel
import BBTestSupport
import Foundation
import Testing
@testable import BBLayout

@MainActor
@Suite("Fonts")
struct FontsTests {
    init() { LayoutFixtures.registerFonts() }

    @Test func fsTypeBitTest() {
        #expect(FontInspector.embeddingAllowed(fsType: 0x0000))   // installable
        #expect(!FontInspector.embeddingAllowed(fsType: 0x0002))  // restricted license
        #expect(!FontInspector.embeddingAllowed(fsType: 0x0102))  // restricted + no-subsetting bit
        #expect(FontInspector.embeddingAllowed(fsType: 0x0004))   // preview & print
        #expect(FontInspector.embeddingAllowed(fsType: 0x0008))   // editable
        #expect(FontInspector.embeddingAllowed(fsType: 0x0006))
        #expect(FontInspector.embeddingAllowed(fsType: 0x0100))
    }

    @Test func inspectBundledFont() throws {
        let url = try #require(TestFonts.url(for: .regular))
        let info = try FontInspector.inspect(url)
        #expect(info.postScriptNames == ["AtkinsonHyperlegible-Regular"])
        #expect(info.familyName.contains("Atkinson"))
        #expect(info.embeddingAllowed)
    }

    @Test func inspectNonFontThrows() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("notafont-\(UUID().uuidString).ttf")
        try Data("hello".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: FontError.self) { try FontInspector.inspect(url) }
    }

    @Test func registerIsIdempotentAndReportsBadFiles() throws {
        let good = try #require(TestFonts.url(for: .bold))
        #expect(FontRegistry.register([good]).isEmpty)
        #expect(FontRegistry.register([good]).isEmpty) // already registered counts as success
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID().uuidString).ttf")
        let failures = FontRegistry.register([missing, good])
        #expect(failures.keys.contains(missing))
        #expect(failures[good] == nil)
    }

    @Test func availabilityAndMissingFonts() {
        #expect(FontAvailability.isAvailable(postScriptName: "AtkinsonHyperlegible-Regular"))
        #expect(FontAvailability.isAvailable(postScriptName: "Helvetica"))
        #expect(!FontAvailability.isAvailable(postScriptName: "No-Such-Font"))
        var typography = LayoutFixtures.typography
        typography.titleFont = FontRef(postScriptName: "Zzz-Missing-Title")
        let text = RichText(paragraphs: [Paragraph(runs: [
            Run(text: "a", fontFamily: "Georgia"),
            Run(text: "b", fontFamily: "Aaa-Missing-Run"),
            Run(text: "", fontFamily: "Empty-Run-Font"),
        ])])
        #expect(FontAvailability.missingFonts(in: [text], typography: typography)
                == ["Aaa-Missing-Run", "Zzz-Missing-Title"])
        #expect(FontAvailability.missingFonts(in: [], typography: LayoutFixtures.typography).isEmpty)
    }
}
