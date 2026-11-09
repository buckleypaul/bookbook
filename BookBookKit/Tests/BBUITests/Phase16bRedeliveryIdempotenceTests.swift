import BBAI
import BBAICore
import BBModel
import Foundation
import Testing
@testable import BBUI

/// Phase 16b: redelivering a picture that is already in the book must not add a second version.
@MainActor
struct Phase16bRedeliveryIdempotenceTests {
    @Test func applyingTheSameDeliveryTwiceMakesOneVersion() throws {
        var content = Fixtures.book()
        let page = Fixtures.firstPage(content)
        let provenance = Fixtures.provenance()
        let (_, item) = BookMutations.makeGeneration(intent: provenance.intent, bookID: content.book.id,
                                                     target: .pageBox(page, Fixtures.imageBox.id), now: Fixtures.date)
        let delivery = GenerationDelivery(item: item, outcome: .success(result: Fixtures.result(),
                                                                        provenance: provenance),
                                          versionID: VersionID())
        let first = BookMutations.applyDelivery(delivery, storedImage: Fixtures.ref, to: &content, now: Fixtures.date)
        let sessionID = try #require(content.pages[page]?.images[Fixtures.imageBox.id]?.sessionID)
        let afterFirst = content.sessions[sessionID]
        #expect(!first.sessions.isEmpty)
        #expect(afterFirst?.versions.map(\.id) == [delivery.versionID])

        let second = BookMutations.applyDelivery(delivery, storedImage: Fixtures.ref, to: &content, now: Fixtures.date)
        #expect(second.sessions.isEmpty)
        #expect(content.sessions[sessionID]?.versions.map(\.id) == [delivery.versionID])
        #expect(content.sessions[sessionID] == afterFirst)
    }
}
