import BBModel
import CoreText
import Foundation

/// What BookBook needs to know about a font file before importing it (A §8.3, Phase 4 contract).
public struct FontFileInfo: Hashable, Sendable {
    /// PostScript names of every face in the file (one for .ttf/.otf, several for .ttc).
    public var postScriptNames: [String]
    public var familyName: String
    /// The raw OS/2 `fsType` value (0 if the table is missing).
    public var fsType: UInt16
    /// False when `fsType` is "restricted license" (bit 1 set, bits 2/3 clear): it can't be
    /// embedded in a PDF. Preview & Print / Editable / installable all count as embeddable.
    public var embeddingAllowed: Bool

    public init(postScriptNames: [String], familyName: String, fsType: UInt16, embeddingAllowed: Bool) {
        self.postScriptNames = postScriptNames
        self.familyName = familyName
        self.fsType = fsType
        self.embeddingAllowed = embeddingAllowed
    }
}

public enum FontError: Error, Hashable, Sendable {
    /// The file isn't a font CoreText can read.
    case unreadable(String)
    case registrationFailed(String)
}

/// Reads font files without registering them.
public enum FontInspector {
    /// Parses names and the OS/2 `fsType` from a .ttf/.otf/.ttc file.
    public static func inspect(_ url: URL) throws(FontError) -> FontFileInfo {
        throw .unreadable("not implemented") // Phase 4 lane B
    }
}

/// Process-scoped font registration for a book's `fonts/` folder (A §8.3).
public enum FontRegistry {
    /// Registers each file with `CTFontManagerRegisterFontURLs(…, .process, …)`. Files already
    /// registered count as success. Returns the files that failed, with their reason.
    @discardableResult
    public static func register(_ urls: [URL]) -> [URL: FontError] {
        [:] // Phase 4 lane B
    }
}

/// Missing-font detection (A §8.3: fallback to the system font plus a book-level warning).
public enum FontAvailability {
    /// True when `NSFont(name:size:)` (or CoreText) resolves this PostScript name.
    public static func isAvailable(postScriptName: String) -> Bool {
        true // Phase 4 lane B
    }

    /// PostScript names used by `texts` (run overrides) or by `typography` (body and title
    /// fonts) that don't resolve, sorted.
    public static func missingFonts(in texts: [RichText], typography: Typography) -> [String] {
        [] // Phase 4 lane B
    }
}
