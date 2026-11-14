import SwiftUI
import Testing
@testable import BBUI

/// Guards the Crayon palette's contrast (WCAG 2) in both appearances, so a palette change can't
/// quietly make labels or status text unreadable. Pure maths over the palette's hex values.
@Suite(.timeLimit(.minutes(1)))
struct CrayonContrastTests {
    static let schemes: [ColorScheme] = [.light, .dark]
    static let fills: [(String, Color)] = [
        ("tomato", Crayon.tomato), ("sunflower", Crayon.sunflower), ("sky", Crayon.sky),
        ("grass", Crayon.grass), ("grape", Crayon.grape), ("bubblegum", Crayon.bubblegum),
        ("inkSoft", Crayon.inkSoft), ("ink", Crayon.ink),
    ]

    private func ratio(_ first: Color, _ second: Color, _ scheme: ColorScheme) throws -> Double {
        let a = try #require(Crayon.swatch(for: first))
        let b = try #require(Crayon.swatch(for: second))
        return CrayonContrast.ratio(a, b, in: scheme)
    }

    @Test func ratioMatchesWCAGReferenceValues() {
        #expect(abs(CrayonContrast.ratio(0xFFFFFF, 0x000000) - 21) < 0.01)
        #expect(abs(CrayonContrast.ratio(0x777777, 0x777777) - 1) < 0.001)
        // White on dark-mode tomato, as measured by the visual audit.
        #expect(abs(CrayonContrast.ratio(0xFFFFFF, 0xFF8466) - 2.40) < 0.01)
        #expect(abs(CrayonContrast.ratio(0xFFFFFF, 0x767676) - 4.54) < 0.01)
    }

    @Test func tokensAreFoundByColour() {
        #expect(Crayon.swatch(for: Crayon.tomato) == Crayon.Swatch.tomato)
        #expect(Crayon.swatch(for: Crayon.rainbow[2]) == Crayon.Swatch.sky)
        #expect(Crayon.swatch(for: .white) != nil)
        #expect(Crayon.swatch(for: Crayon.tomato.opacity(0.5)) == nil)
    }

    @Test(arguments: schemes)
    func buttonAndStickerLabelsReachAAOnEveryFill(scheme: ColorScheme) throws {
        for (name, fill) in Self.fills {
            let label = CrayonContrast.label(on: fill, preferring: .white, minimum: CrayonContrast.text, in: scheme)
            let contrast = try ratio(label, fill, scheme)
            #expect(contrast >= CrayonContrast.text, "\(name) in \(scheme): \(contrast)")
        }
    }

    @Test(arguments: schemes)
    func bannerGlyphsReachNonTextContrast(scheme: ColorScheme) throws {
        for (name, fill) in Self.fills {
            let glyph = CrayonContrast.label(on: fill, preferring: .white, minimum: CrayonContrast.graphics, in: scheme)
            let contrast = try ratio(glyph, fill, scheme)
            #expect(contrast >= CrayonContrast.graphics, "\(name) in \(scheme): \(contrast)")
        }
        #expect(try ratio(Crayon.onSunflower, Crayon.sunflower, scheme) >= CrayonContrast.text)
        let sunflowerGlyph = CrayonContrast.label(on: Crayon.sunflower, preferring: Crayon.onSunflower,
                                                  minimum: CrayonContrast.graphics, in: scheme)
        #expect(sunflowerGlyph == Crayon.onSunflower)
    }

    @Test func whiteIsKeptWhereItPasses() {
        // inkSoft is dark enough in light mode for white text.
        let label = CrayonContrast.label(on: Crayon.inkSoft, preferring: .white, minimum: CrayonContrast.text, in: .light)
        #expect(label == .white)
    }

    @Test func unknownColoursKeepThePreferredLabel() {
        let fill = Color(red: 0.9, green: 0.9, blue: 0.9)
        #expect(CrayonContrast.label(on: fill, preferring: .white, minimum: CrayonContrast.text, in: .light) == .white)
    }

    @Test(arguments: schemes)
    func statusTextReachesAAOnPaperAndCard(scheme: ColorScheme) throws {
        let texts: [(String, Color)] = [
            ("danger", Crayon.danger), ("warning", Crayon.warning), ("success", Crayon.success), ("ink", Crayon.ink),
        ]
        for (name, text) in texts {
            for (surfaceName, surface) in [("paper", Crayon.paper), ("card", Crayon.card)] {
                let contrast = try ratio(text, surface, scheme)
                #expect(contrast >= CrayonContrast.text, "\(name) on \(surfaceName) in \(scheme): \(contrast)")
            }
        }
    }
}
