import BBAICore
import BBModel
import Foundation
import SnapshotTesting
import Testing
@testable import BBAI

/// A one-page book with the slice template shape: image box on top, text box below.
struct SliceBook {
    var content: BookContent
    var pageID: PageID
    var imageBox: BoxID
    var textBox: BoxID

    static func make(overlappingText: Bool = false, text: String = "The little fox found a red umbrella.",
                     style: String = "Soft watercolor, warm light.") -> SliceBook {
        let imageBox = Box(frame: NormalizedRect(x: 0.06, y: 0.05, width: 0.88, height: 0.57), content: .image)
        let textFrame = overlappingText
            ? NormalizedRect(x: 0.06, y: 0.43, width: 0.88, height: 0.19)
            : NormalizedRect(x: 0.06, y: 0.66, width: 0.88, height: 0.28)
        let textBox = Box(frame: textFrame, content: .text(TextBoxStyle()))
        let template = Template(name: "Slice", kind: .single, boxes: [imageBox, textBox])
        let cover = Template(name: "Cover", kind: .cover, boxes: [])
        var content = BookContent.makeNew(title: "T", storyTemplate: template, coverTemplate: cover, now: Date(timeIntervalSince1970: 0))
        let pageID = content.book.pageOrder[0]
        content.pages[pageID]?.text[textBox.id] = RichText(plain: text)
        content.style.visualDescription = style
        content.style.visualRevision = 3
        return SliceBook(content: content, pageID: pageID, imageBox: imageBox.id, textBox: textBox.id)
    }

    var target: GenerationTarget { .pageBox(pageID, imageBox) }
}

func intent(_ message: String = "A fox under a red umbrella in the rain.", story: Bool = true,
            quality: QualityLevel = .draft) -> GenerationIntent {
    GenerationIntent(messageText: message, provider: .openai, model: "gpt-image-2.5-sunburst",
                     quality: quality, includeStoryText: story)
}

/// Prompt snapshots live in `Tests/BBAISnapshots/ContextAssemblerTests/`, outside the test target folder, so
/// SwiftPM does not warn about unhandled files (Package.swift is not ours to edit).
func assertPromptSnapshot(_ text: String, file: StaticString = #filePath, testName: String = #function,
                          line: UInt = #line) {
    let directory = URL(fileURLWithPath: "\(file)").deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("BBAISnapshots/ContextAssemblerTests", isDirectory: true)
    if let failure = verifySnapshot(of: text, as: .lines, snapshotDirectory: directory.path, file: file,
                                    testName: testName, line: line) {
        Issue.record(Comment(rawValue: failure))
    }
}

struct MissingDefaultModel: Error {}

func testModel() throws -> CatalogModel {
    guard let model = try ModelCatalog.bundled().defaultImageModel(for: .openai) else { throw MissingDefaultModel() }
    return model
}
