import AppKit
import Testing
@testable import BBExport

private let hasEnglishDictionary = NSLocale.availableLocaleIdentifiers.contains { $0.hasPrefix("en") }
    && !NSSpellChecker.availableLanguages_nonisolated.isEmpty

private extension NSSpellChecker {
    /// `availableLanguages` is main-actor; the trait needs a nonisolated value.
    static var availableLanguages_nonisolated: [String] {
        MainActor.assumeIsolated { NSSpellChecker.shared.availableLanguages.filter { $0.hasPrefix("en") } }
    }
}

@MainActor
struct SystemSpellingCheckerTests {
    @Test func emptyStringGivesNoWords() {
        #expect(SystemSpellingChecker().misspelledWords(in: "").isEmpty)
    }

    @Test(.enabled(if: hasEnglishDictionary, "No English dictionary installed"))
    func flagsTeh() {
        #expect(SystemSpellingChecker().misspelledWords(in: "The teh fox.").contains("teh"))
    }
}
