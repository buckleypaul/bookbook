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
    /// False when `fsType` is "restricted license" (bit 1 set, bits 2/3 clear) or
    /// "bitmap embedding only" (bit 9): it can't be embedded in a PDF as outlines.
    /// Preview & Print / Editable / installable all count as embeddable.
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
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              !descriptors.isEmpty
        else { throw .unreadable(url.lastPathComponent) }
        var names: [String] = []
        for descriptor in descriptors {
            if let name = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String,
               !names.contains(name) { names.append(name) }
        }
        guard !names.isEmpty else { throw .unreadable(url.lastPathComponent) }
        let first = descriptors[0]
        let family = (CTFontDescriptorCopyAttribute(first, kCTFontFamilyNameAttribute) as? String) ?? names[0]
        let font = CTFontCreateWithFontDescriptor(first, 12, nil)
        var fsType: UInt16 = 0
        if let table = CTFontCopyTable(font, CTFontTableTag(kCTFontTableOS2), []) {
            let data = table as Data
            if data.count >= 10 {
                fsType = (UInt16(data[data.startIndex + 8]) << 8) | UInt16(data[data.startIndex + 9])
            }
        }
        return FontFileInfo(postScriptNames: names, familyName: family, fsType: fsType,
                            embeddingAllowed: embeddingAllowed(fsType: fsType))
    }

    /// False for "restricted license" embedding (bit 1 set with bits 2 and 3 clear) and for
    /// "bitmap embedding only" (bit 9, `0x0200`): a PDF needs the outlines (Phase 16b #80b).
    static func embeddingAllowed(fsType: UInt16) -> Bool {
        fsType & 0x000E != 0x0002 && fsType & 0x0200 == 0
    }
}

/// Process-scoped font registration for a book's `fonts/` folder (A §8.3).
public enum FontRegistry {
    /// Registers each file with `CTFontManagerRegisterFontURLs(…, .process, …)`. Files already
    /// registered count as success. Returns the files that failed, with their reason.
    @discardableResult
    public static func register(_ urls: [URL]) -> [URL: FontError] {
        var failures: [URL: FontError] = [:]
        for url in urls {
            var error: Unmanaged<CFError>?
            if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) { continue }
            guard let cfError = error?.takeRetainedValue() else {
                failures[url] = .registrationFailed(url.lastPathComponent)
                continue
            }
            let code = CFErrorGetCode(cfError)
            if code == CTFontManagerError.alreadyRegistered.rawValue { continue }
            if code == CTFontManagerError.invalidFontData.rawValue || code == CTFontManagerError.fileNotFound.rawValue {
                failures[url] = .unreadable(url.lastPathComponent)
            } else {
                failures[url] = .registrationFailed(CFErrorCopyDescription(cfError) as String)
            }
        }
        return failures
    }
}

/// Missing-font detection (A §8.3: fallback to the system font plus a book-level warning).
public enum FontAvailability {
    /// True when `NSFont(name:size:)` (or CoreText) resolves this PostScript name.
    public static func isAvailable(postScriptName: String) -> Bool {
        CTFontDescriptorCreateWithNameAndSize(postScriptName as CFString, 12).matchingFontDescriptor(
            postScriptName: postScriptName)
    }

    /// PostScript names used by `texts` (run overrides) or by `typography` (body and title
    /// fonts) that don't resolve, sorted.
    public static func missingFonts(in texts: [RichText], typography: Typography) -> [String] {
        var names: Set<String> = [typography.bodyFont.postScriptName, typography.titleFont.postScriptName]
        for text in texts {
            for paragraph in text.paragraphs {
                for run in paragraph.runs where !run.text.isEmpty {
                    if let name = run.fontFamily { names.insert(name) }
                }
            }
        }
        return names.filter { !isAvailable(postScriptName: $0) }.sorted()
    }
}

private extension CTFontDescriptor {
    /// True when CoreText resolves a font whose PostScript name is exactly `postScriptName`.
    func matchingFontDescriptor(postScriptName: String) -> Bool {
        let font = CTFontCreateWithFontDescriptor(self, 12, nil)
        return CTFontCopyPostScriptName(font) as String == postScriptName
    }
}
