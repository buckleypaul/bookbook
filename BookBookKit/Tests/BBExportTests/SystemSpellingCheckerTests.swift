import AppKit
import Testing
@testable import BBExport

/// Trait conditions run off the main actor, and `NSSpellChecker` is main-actor
/// only, so hop to the main actor rather than assuming we're already on it.
@Sendable private func hasEnglishDictionary() async -> Bool {
    await MainActor.run {
        NSLocale.availableLocaleIdentifiers.contains { $0.hasPrefix("en") }
            && NSSpellChecker.shared.availableLanguages.contains { $0.hasPrefix("en") }
    }
}

@MainActor
struct SystemSpellingCheckerTests {
    @Test func emptyStringGivesNoWords() {
        #expect(SystemSpellingChecker().misspelledWords(in: "").isEmpty)
    }

    @Test(.enabled("No English dictionary installed", hasEnglishDictionary))
    func flagsAnEnglishTypo() {
        // Not "teh": with the language chosen automatically, macOS accepts it (it's a word in
        // Malay and Indonesian), so it is no test of the checker.
        #expect(SystemSpellingChecker().misspelledWords(in: "The fox was happy becuase.") == ["becuase"])
    }
}
