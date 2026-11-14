import BBAI
import BBModel
import Foundation
import Testing
@testable import BBUI

@MainActor
struct Phase16bSessionTests {
    private let box = Fixtures.imageBox.id

    private func ref(_ n: Int) -> ImageRef {
        ImageRef(sha256: String(repeating: String(format: "%02x", n), count: 32), contentType: "public.png")
    }

    @Test func deletingAMiddleVersionReparentsItsChildren() {
        var content = Fixtures.book()
        let page = Fixtures.firstPage(content)
        let sid = content.pages[page]!.images[box]!.sessionID
        let a = VersionID(), b = VersionID(), c = VersionID()
        var parent: VersionID?
        for (n, id) in [a, b, c].enumerated() {
            content.sessions[sid]!.versions.append(
                Version(id: id, image: ref(n + 1), pixelSize: PixelSize(width: 10, height: 10), source: .generated,
                        parent: parent, createdAt: Fixtures.date))
            parent = id
        }
        _ = BookMutations.deleteVersion(b, in: sid, to: &content)
        let session = content.sessions[sid]!
        #expect(session.versions.first { $0.id == c }?.parent == a)
        #expect(session.lineage(of: c).map(\.id) == [a, c])
    }

    @Test func confirmButtonNamesTheAction() {
        #expect(CostConfirmKind.generate.buttonTitle == "Generate")
        #expect(CostConfirmKind.checkConsistency.buttonTitle == "Check")
        #expect(CostConfirmKind.fixConsistency.buttonTitle == "Fix")
        #expect(CostConfirmKind.regionEdit.buttonTitle == "Edit Region")
    }

    @Test func sessionHeaderNamesTheBox() {
        let content = Fixtures.book()
        let page = Fixtures.firstPage(content)
        #expect(SessionPanel.headerTitle(page: page, box: Fixtures.imageBox.id, in: content) == "Image")
        let cover = content.book.coverPageID
        #expect(SessionPanel.headerTitle(page: cover, box: Fixtures.coverTemplate.boxes[0].id, in: content)
                == "Cover Image")
    }

    @Test func batchAlertNamesTheCover() {
        let est = CostEstimate(amount: Decimal(string: "0.5")!)
        let decision = CostDecision(needsConfirmation: false, overBudget: false)
        let text = CostText.batchAlert(count: 13, estimate: est, decision: decision, spent: 0, budget: nil,
                                       coverIncluded: true)
        #expect(text.hasPrefix("13 pictures (cover + 12 pages),"))
        let plain = CostText.batchAlert(count: 12, estimate: est, decision: decision, spent: 0, budget: nil)
        #expect(plain.hasPrefix("12 pictures,"))
        // A page with two empty boxes is still one page.
        let twoBoxes = CostText.batchAlert(count: 3, estimate: est, decision: decision, spent: 0, budget: nil,
                                           coverIncluded: true, pageCount: 1)
        #expect(twoBoxes.hasPrefix("3 pictures (cover + 1 page),"))
        // The limit remark follows the estimate, then the budget.
        let over = CostText.batchAlert(count: 2, estimate: est, decision: .init(needsConfirmation: true, overBudget: true),
                                       spent: 9, budget: 10)
        #expect(over == "2 pictures, about $0.50. That's above your confirmation limit. "
                + "This book has spent $9.00 of its $10.00 budget.")
    }

    @Test func badgeSaysPausedWhilePaused() {
        let paused = QueueBadgeModel(snapshot: QueueSnapshot(entries: [], pause: .user))
        #expect(paused.title.hasSuffix("(paused)"))
        #expect(!QueueBadgeModel(snapshot: QueueSnapshot()).title.contains("paused"))
    }

    @Test func committedTextOnlyCommitsATypedDraft() {
        #expect(CommittedText.textToCommit(draft: "old", value: "old") == nil)
        #expect(CommittedText.textToCommit(draft: "new", value: "old") == "new")
    }
}
