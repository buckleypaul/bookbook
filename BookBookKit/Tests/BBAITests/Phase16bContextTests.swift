import BBModel
import Foundation
import Testing
@testable import BBAI

@Suite struct Phase16bContextTests {
    @Test func renderIsASingleScan() {
        // A value containing another placeholder's syntax is not expanded.
        let out = PromptTemplates.render("{{label}} of {{name}}", ["label": "{{name}}", "name": "Pip"])
        #expect(out == "{{name}} of Pip")
        #expect(PromptTemplates.render("{{unknown}} and {{name}} {{", ["name": "Pip"]) == "{{unknown}} and Pip {{")
    }

    @Test func resolveIsNilWhenMessageSessionHasNoSlotAndTargetBoxIsAnotherSessions() throws {
        var book = SliceBook.make()
        // A session that no box holds any more, with a message in it.
        let message = Message(role: .user, text: "hi", createdAt: Date(timeIntervalSince1970: 0))
        let orphan = Session(owner: .pageBox(book.pageID, BoxID()), messages: [message])
        book.content.sessions[orphan.id] = orphan
        #expect(ContextAssembler.resolve(target: book.target, messageID: message.id, content: book.content) == nil)
        // Without the message the target's own session still resolves.
        #expect(ContextAssembler.resolve(target: book.target, messageID: nil, content: book.content) != nil)
    }
}
