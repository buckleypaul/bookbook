import Foundation
import Testing
@testable import BBModel

/// Phase 16b: "style changed" is a difference, not just "older" (A §4.4), and the revision
/// high-water mark survives odd files.
struct Phase16bStyleFlagTests {
    @Test func imageGeneratedAtNewerRevision_isFlaggedAfterUndoBack() {
        var (content, page, box) = StyleFlagsTests.book(provenance: StyleFlagsTests.provenance(styleRevision: 2))
        content.style.visualRevision = 1   // the style edit that made revision 2 was undone
        #expect(content.imageFlags(page: page, box: box).contains(.styleChanged))
        content.style.visualRevision = 2
        #expect(!content.imageFlags(page: page, box: box).contains(.styleChanged))
    }

    @Test func acknowledgingTheCurrentRevisionClearsIt() {
        var (content, page, box) = StyleFlagsTests.book(provenance: StyleFlagsTests.provenance(styleRevision: 2))
        content.style.visualRevision = 1
        content.pages[page]?.images[box]?.acknowledged.styleRevision = 1
        #expect(!content.imageFlags(page: page, box: box).contains(.styleChanged))
    }

    @Test func decodingHighWaterBelowVisualRevision_raisesIt() throws {
        var style = BookContent.makeNew(title: "T", storyTemplate: StyleFlagsTests.story,
                                        coverTemplate: StyleFlagsTests.cover, now: StyleFlagsTests.now).style
        style.visualRevision = 4
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(style)) as? [String: Any])
        json["visualRevisionHighWater"] = 2
        let decoded = try JSONDecoder().decode(StyleGuide.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.visualRevisionHighWater == 4)
        var visual = decoded.visual
        visual.visualDescription = "new"
        #expect(decoded.applying(visual).visualRevision == 5, "a number is never reused")
    }
}
