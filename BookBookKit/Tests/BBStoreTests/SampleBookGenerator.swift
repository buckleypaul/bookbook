import BBModel
import Foundation
import Testing
@testable import BBStore

/// Regenerates the text-only placeholder sample book. A no-op unless `BOOKBOOK_GENERATE_SAMPLE=1`:
///
///     BOOKBOOK_GENERATE_SAMPLE=1 swift test --filter SampleBookGenerator
///
/// It rewrites `Sources/BBStore/Resources/SampleBook/Sample.bookbook`. Replace that package with
/// an in-app book (with pictures) when it is made; see the README next to it.
struct SampleBookGenerator {
    static let story = [
        "Pip the frog lived at the edge of Willow Pond, where the evenings were very quiet.",
        "One night the moon slipped behind a cloud, and the whole pond went dark.",
        "“I will find it,” said Pip, and he hopped onto the biggest lily pad.",
        "The fireflies lent him their light, and the old heron showed him the way.",
        "At the top of the hill, the moon was only resting on a pillow of mist.",
        "Pip gave a gentle croak, the moon rose again, and every ripple on the pond began to shine.",
    ]

    @Test func generate() throws {
        guard ProcessInfo.processInfo.environment["BOOKBOOK_GENERATE_SAMPLE"] == "1" else { return }
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let story = try Presets.storyTemplate()
        let cover = try Presets.coverTemplate()
        var content = BookContent.makeNew(title: "Pip and the Missing Moon", author: "BookBook Sample",
                                          storyTemplate: story, coverTemplate: cover,
                                          storyPageCount: Self.story.count, now: date)
        let textBox = try #require(story.textBoxes.first?.id)
        for (id, line) in zip(content.book.pageOrder, Self.story) {
            content.pages[id]?.text[textBox] = RichText(plain: line)
        }
        content = NewBookSpec(
            title: content.book.title, author: content.book.author, pageSize: .eightByTen, orientation: .portrait,
            stylePresetID: "watercolour",
            mainCharacter: .init(name: "Pip",
                                 description: "A small, round green frog with big gold eyes and a tiny red scarf.")
        ).apply(to: content)

        let here = URL(fileURLWithPath: #filePath)
        let dest = here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/BBStore/Resources/SampleBook/Sample.bookbook", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: dest)
        try BookStore.create(content, at: dest)
    }
}
