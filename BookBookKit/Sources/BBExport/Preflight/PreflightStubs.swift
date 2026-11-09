import BBLayout
import BBModel
import Foundation

// Phase 14 preflight lane: replace these stubs (keep the public signatures).

@MainActor
public final class SystemSpellingChecker: SpellingChecking {
    public init() {}
    public func misspelledWords(in text: String) -> [String] {
        fatalError("SystemSpellingChecker not implemented")
    }
}

@MainActor
public enum Preflight {
    public static func run(_ content: BookContent,
                           assessments: [BoxImageKey: ImageAssessment],
                           spelling: any SpellingChecking) -> [PreflightIssue] {
        fatalError("Preflight.run not implemented")
    }
}
