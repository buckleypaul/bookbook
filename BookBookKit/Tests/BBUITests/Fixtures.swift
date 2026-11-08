import BBAI
import BBAICore
import BBModel
import Foundation

/// Hand-built book content for BBUI tests (no presets, no I/O).
enum Fixtures {
    static let imageBox = Box(frame: NormalizedRect(x: 0.1, y: 0.1, width: 0.8, height: 0.5), content: .image)
    static let textBox = Box(frame: NormalizedRect(x: 0.1, y: 0.65, width: 0.8, height: 0.25),
                             content: .text(TextBoxStyle(padding: 4)))
    static let storyTemplate = Template(name: "Image above text", kind: .single, boxes: [imageBox, textBox])
    static let coverTemplate = Template(name: "Cover", kind: .cover, boxes: [
        Box(frame: NormalizedRect(x: 0, y: 0, width: 1, height: 1), content: .image),
    ])
    static let date = Date(timeIntervalSince1970: 1_800_000_000)

    static func book(pages: Int = 1) -> BookContent {
        BookContent.makeNew(title: "Test", storyTemplate: storyTemplate, coverTemplate: coverTemplate,
                            storyPageCount: pages, now: date)
    }

    static func firstPage(_ content: BookContent) -> PageID { content.book.pageOrder[0] }

    static func provenance(prompt: String = "PROMPT", refines: VersionID? = nil) -> Provenance {
        let intent = GenerationIntent(messageText: "a fox", refines: refines, provider: .openai,
                                      model: "gpt-image-2.5-sunburst", quality: .standard)
        return Provenance(provider: .openai, model: "gpt-image-2.5-sunburst", quality: .standard,
                          outputSize: PixelSize(width: 1024, height: 1536), promptSent: prompt, styleRevision: 0,
                          storyTextIncluded: true, intent: intent,
                          usage: TokenUsage(inputTextTokens: 120, outputImageTokens: 4160),
                          parametersSent: ["size": "1024x1536", "quality": "medium", "n": "1"])
    }

    static func result() -> ImageResult {
        ImageResult(imageData: Data([1, 2, 3]), contentType: "public.png", pixelSize: PixelSize(width: 1024, height: 1536))
    }

    static let ref = ImageRef(sha256: String(repeating: "ab", count: 32), contentType: "public.png")
}
