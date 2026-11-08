import Foundation
import Testing
@testable import BBModel

@Suite struct SessionLineageTests {
    let now = Date(timeIntervalSince1970: 0)

    func version(_ n: Int, parent: Version? = nil) -> Version {
        Version(image: ImageRef(sha256: "h\(n)", contentType: "public.png"), pixelSize: PixelSize(width: 100, height: 100),
                source: .generated, parent: parent?.id, createdAt: now)
    }

    func message(_ text: String, produced: Version?, epoch: Int = 0, role: MessageRole = .user) -> Message {
        Message(epoch: epoch, role: role, text: text, producedVersion: produced?.id, createdAt: now)
    }

    /// v1 -> v2 -> v3 -> v4, and v1 -> v5.
    func tree() -> (Session, [Version]) {
        let v1 = version(1), v2 = version(2, parent: v1), v3 = version(3, parent: v2), v4 = version(4, parent: v3)
        let v5 = version(5, parent: v1)
        let messages = [message("a fox", produced: v1), message("bluer", produced: v2), message("bigger", produced: v3),
                        message("rain", produced: v4), message("a hat", produced: v5)]
        let session = Session(owner: .pageBox(PageID(), BoxID()), messages: messages, versions: [v1, v2, v3, v4, v5])
        return (session, [v1, v2, v3, v4, v5])
    }

    @Test func branchLineageUsesOnlyAncestors() {
        let (session, v) = tree()
        #expect(session.lineage(of: v[4].id).map(\.id) == [v[0].id, v[4].id])
        #expect(session.lineage(of: v[3].id).map(\.id) == [v[0].id, v[1].id, v[2].id, v[3].id])
        #expect(session.lineage(of: v[0].id).map(\.id) == [v[0].id])
        #expect(session.lineage(of: VersionID()).isEmpty)
        // Later versions are untouched by lineage queries.
        #expect(session.versions.count == 5)
    }

    @Test func instructionsFollowTheBranch() {
        let (session, v) = tree()
        #expect(session.lineageInstructions(of: v[4].id).map(\.text) == ["a fox", "a hat"])
        #expect(session.lineageInstructions(of: v[2].id).map(\.text) == ["a fox", "bluer", "bigger"])
        #expect(session.versionNumber(v[4].id) == 5)
        #expect(session.versionNumber(VersionID()) == nil)
    }

    @Test func danglingAndCyclicParentsEndTheChain() {
        var v1 = version(1)
        v1.parent = VersionID()
        var v2 = version(2)
        var v3 = version(3)
        v2.parent = v3.id
        v3.parent = v2.id
        let session = Session(owner: .pageBox(PageID(), BoxID()), versions: [v1, v2, v3])
        #expect(session.lineage(of: v1.id).map(\.id) == [v1.id])
        #expect(Set(session.lineage(of: v2.id).map(\.id)) == [v2.id, v3.id])
    }

    @Test func earlierEpochsAreHidden() {
        let (base, v) = tree()
        var session = base
        session.resetEpoch = 1
        session.messages.append(message("fresh start", produced: v[0], epoch: 1))
        session.messages.append(message("assistant note", produced: v[0], epoch: 1, role: .assistant))
        #expect(session.visibleMessages.map(\.text) == ["fresh start", "assistant note"])
        #expect(session.lineageInstructions(of: v[4].id).map(\.text) == ["fresh start"])
    }

    @Test func sessionContainingMessage() {
        let (session, _) = tree()
        var content = BookContent.makeNew(
            title: "T", storyTemplate: Template(name: "S", kind: .single, boxes: []),
            coverTemplate: Template(name: "C", kind: .cover, boxes: []), now: now)
        content.sessions[session.id] = session
        #expect(content.session(containing: session.messages[2].id)?.id == session.id)
        #expect(content.session(containing: MessageID()) == nil)
    }
}
