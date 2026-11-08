import CoreText
import Foundation

/// The bundled test font (Atkinson Hyperlegible, SIL OFL 1.1), so snapshot tests don't depend
/// on which system fonts are installed (implementation-plan.md Phase 1 deliverables).
public enum TestFonts {
    public enum Face: String, Sendable, CaseIterable {
        case regular = "AtkinsonHyperlegible-Regular"
        case bold = "AtkinsonHyperlegible-Bold"
    }

    /// URL of a bundled font file.
    public static func url(for face: Face) -> URL? {
        Bundle.module.url(forResource: face.rawValue, withExtension: "ttf", subdirectory: "Fonts")
    }

    /// Registers every bundled face for this process. Safe to call more than once.
    /// Returns `false` if any face is missing or fails to register for a reason other than
    /// already being registered.
    @discardableResult
    public static func registerAll() -> Bool {
        var ok = true
        for face in Face.allCases {
            guard let url = url(for: face) else { ok = false; continue }
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                let code = (error?.takeRetainedValue()).map { CFErrorGetCode($0) } ?? 0
                if code != CTFontManagerError.alreadyRegistered.rawValue { ok = false }
            }
        }
        return ok
    }
}
