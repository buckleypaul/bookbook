// Bundled test font: Atkinson Hyperlegible 1.006, Regular and Bold (TTF), SIL OFL 1.1.
// Source: https://github.com/google/fonts/tree/95f4904fc8bcf26d3420fe315560c96417c6dec7/ofl/atkinsonhyperlegible
//   (upstream commit 95f4904, 2026-03-03, last commit touching that folder; licence file OFL.txt).
//   Files: AtkinsonHyperlegible-Regular.ttf, AtkinsonHyperlegible-Bold.ttf, OFL.txt, copied unchanged.
//   SHA-256: Regular 7fb917c89019896d0b52ee84b7cbb3304c18cb90b19a62f5e32712bd23e97669
//            Bold    5a3b0c8cc8ca545155150b4512a1fa248298df121c50d6557e651e61fbdab92f
//   Copyright 2020 Braille Institute of America, Inc.
import CoreText
import Foundation
import Testing
@testable import BBTestSupport

@Suite struct TestFontsTests {
    @Test func everyFaceHasABundledFile() {
        for face in TestFonts.Face.allCases {
            guard let url = TestFonts.url(for: face) else {
                Issue.record("missing bundled font \(face.rawValue)")
                continue
            }
            #expect(url.isFileURL)
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test func registerAllSucceedsAndIsIdempotent() {
        #expect(TestFonts.registerAll())
        #expect(TestFonts.registerAll())
    }

    @Test func registeredRegularFaceResolvesByPostScriptName() {
        #expect(TestFonts.registerAll())
        let font = CTFontCreateWithName("AtkinsonHyperlegible-Regular" as CFString, 12, nil)
        #expect(CTFontCopyPostScriptName(font) as String == "AtkinsonHyperlegible-Regular")
    }

    @Test func registeredBoldFaceResolvesByPostScriptName() {
        #expect(TestFonts.registerAll())
        let font = CTFontCreateWithName("AtkinsonHyperlegible-Bold" as CFString, 12, nil)
        #expect(CTFontCopyPostScriptName(font) as String == "AtkinsonHyperlegible-Bold")
    }
}
