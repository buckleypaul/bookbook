import AppKit
import BBLayout
import BBModel
import Foundation

/// `NSSpellChecker`-backed spelling (language chosen automatically).
@MainActor
public final class SystemSpellingChecker: SpellingChecking {
    public init() {}

    public func misspelledWords(in text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        let checker = NSSpellChecker.shared
        let ns = text as NSString
        var words: [String] = []
        var offset = 0
        while offset < ns.length {
            let range = checker.checkSpelling(of: text, startingAt: offset, language: nil, wrap: false,
                                              inSpellDocumentWithTag: 0, wordCount: nil)
            guard range.location != NSNotFound, range.length > 0 else { break }
            words.append(ns.substring(with: range))
            offset = range.location + range.length
        }
        return words
    }
}

@MainActor
private final class NoImages: PageImageSource {
    func image(for ref: ImageRef) -> CGImage? { nil }
}

/// A §9.4: the "Before export" checks (PD §8.8).
@MainActor
public enum Preflight {
    public static func run(_ content: BookContent,
                           assessments: [BoxImageKey: ImageAssessment],
                           spelling: any SpellingChecking) -> [PreflightIssue] {
        let renderer = PageRenderer(images: NoImages())
        var pages: [Page] = []
        if let cover = content.coverPage { pages.append(cover) }
        pages += content.storyPages.filter { $0.id != content.book.coverPageID }

        var issues: [PreflightIssue] = []
        for page in pages {
            guard let template = content.template(for: page) else { continue }
            let texts: [(Box, RichText)] = template.boxes.compactMap { box in
                guard case .text = box.content,
                      let text = CoverText.boundText(for: box.role, book: content.book) ?? page.text[box.id]
                else { return nil }
                return (box, text)
            }
            let imageBoxes = template.imageBoxes

            for box in imageBoxes where content.placedVersion(page: page.id, box: box.id) == nil {
                issues.append(PreflightIssue(kind: .emptyImageBox, page: page.id, box: box.id,
                                             detail: "Image box has no image"))
            }

            let overflowing = renderer.overflowingTextBoxes(page: page, in: content)
            for box in template.boxes where overflowing.contains(box.id) {
                issues.append(PreflightIssue(kind: .textOverflow, page: page.id, box: box.id,
                                             detail: "Text doesn't fit its box"))
            }

            for (box, text) in texts {
                for word in spelling.misspelledWords(in: text.plainText) {
                    issues.append(PreflightIssue(kind: .spelling, page: page.id, box: box.id, detail: "“\(word)”"))
                }
            }

            for box in imageBoxes {
                guard let a = assessments[BoxImageKey(page: page.id, box: box.id)], a.isSoft else { continue }
                let have = Int(a.availablePixels.width.rounded())
                let need = Int(a.requiredPixels.width.rounded())
                issues.append(PreflightIssue(kind: .softImage, page: page.id, box: box.id,
                                             detail: "\(have) px available; needs \(need) px"))
            }

            let flagKinds: [(ImageFlags, PreflightIssue.Kind, String)] = [
                (.styleChanged, .styleChanged, "Book style changed since this image was made"),
                (.assetChanged, .assetChanged, "An asset changed since this image was made"),
                (.layoutChanged, .layoutChanged, "Box shape changed since this image was placed"),
                (.consistencyWarning, .consistencyWarning, "Consistency check found a problem"),
            ]
            for (flag, kind, detail) in flagKinds {
                for box in imageBoxes where content.imageFlags(page: page.id, box: box.id).contains(flag) {
                    issues.append(PreflightIssue(kind: kind, page: page.id, box: box.id, detail: detail))
                }
            }

            let missing = FontAvailability.missingFonts(in: texts.map(\.1), typography: content.style.typography)
            for name in missing {
                issues.append(PreflightIssue(kind: .missingFont, page: page.id,
                                             detail: "Font “\(name)” isn't installed"))
            }
        }
        return issues
    }
}
