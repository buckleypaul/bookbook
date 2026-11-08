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

    /// One image box and no text boxes, on a 500x500 pt page with 25 pt margins and a 9 pt bleed (when `bleed`).
    static func makeCustom(kind: TemplateKind, frame: NormalizedRect, bleed: Bool = false,
                           bleedEdges: EdgeSet = []) -> SliceBook {
        let imageBox = Box(frame: frame, bleedEdges: bleedEdges, content: .image)
        let template = Template(name: "Custom", kind: kind, boxes: [imageBox])
        let cover = Template(name: "Cover", kind: .cover, boxes: [])
        var content = BookContent.makeNew(title: "T", storyTemplate: template, coverTemplate: cover, now: Date(timeIntervalSince1970: 0))
        content.style.pageSetup = PageSetup(trimSize: PointSize(width: 500, height: 500), orientation: .portrait,
                                            margins: EdgeInsetsPt(all: 25), bleedEnabled: bleed, bleedAmount: 9)
        content.style.visualDescription = "Soft watercolor, warm light."
        let pageID = content.book.pageOrder[0]
        return SliceBook(content: content, pageID: pageID, imageBox: imageBox.id, textBox: BoxID())
    }

    var sessionID: SessionID { content.pages[pageID]!.images[imageBox]!.sessionID }
}

/// Four generated versions in a chain (v1 to v4) plus a pending message, as in the Phase 8 acceptance walk.
struct RefinementBook {
    var book: SliceBook
    var versions: [Version]
    var pendingMessage: MessageID

    static func make(chain: Int = 4) -> RefinementBook {
        var book = SliceBook.make()
        var versions: [Version] = []
        var messages: [Message] = []
        let texts = ["A fox in the rain", "make the sky blue", "add a hat", "bigger umbrella"]
        for n in 0..<chain {
            let version = Version(image: ImageRef(sha256: "sha\(n + 1)", contentType: "public.png"),
                                  pixelSize: PixelSize(width: 1024, height: 672), source: .generated,
                                  parent: versions.last?.id, createdAt: Date(timeIntervalSince1970: Double(n)))
            versions.append(version)
            messages.append(Message(role: .user, text: texts[n], producedVersion: version.id, createdAt: Date(timeIntervalSince1970: Double(n))))
            messages.append(Message(role: .assistant, text: "refined version \(n + 1)", createdAt: Date(timeIntervalSince1970: Double(n))))
        }
        let pending = Message(role: .user, text: "now with a cat", queueItemID: QueueItemID(), createdAt: Date(timeIntervalSince1970: 10))
        messages.append(pending)
        let id = book.sessionID
        book.content.sessions[id]?.versions = versions
        book.content.sessions[id]?.messages = messages
        return RefinementBook(book: book, versions: versions, pendingMessage: pending.id)
    }

    /// Bytes for every version image.
    var imageData: [ImageRef: Data] {
        Dictionary(uniqueKeysWithValues: versions.map { ($0.image, Data("bytes-\($0.image.sha256)".utf8)) })
    }

    func refine(_ index: Int, _ text: String = "now with a cat", attached: [VersionRef] = []) -> GenerationIntent {
        var value = intent(text, story: false)
        value.refines = versions[index].id
        value.attachedReferences = attached
        return value
    }
}

func assembleBook(_ book: SliceBook, _ intent: GenerationIntent = intent(), content: BookContent? = nil,
                  messageID: MessageID? = nil, model: CatalogModel? = nil,
                  imageData: [ImageRef: Data] = [:]) throws -> (ImageRequest, AssemblyReport) {
    try ContextAssembler.assemble(intent: intent, target: book.target, messageID: messageID,
                                  content: content ?? book.content, model: model ?? testModel(), imageData: imageData)
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
