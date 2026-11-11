import BBAI
import BBAICore
import BBModel
import BBStore
import Foundation
import Testing
@testable import BBUI

/// "Draft all empty boxes" (PD §8.5, A §7.9 batch actions).
@MainActor
struct DraftAllTests {
    private struct Setup {
        var h: Phase9Harness
        var app: AppModel
        var document: BookDocument
    }

    /// A book with a cover and `pages` story pages (one image box each), saved to a temp package.
    private func setup(pages: Int = 3, edit: (inout BookContent) -> Void = { _ in }) throws -> Setup {
        let h = try Phase9Harness()
        var content = Fixtures.book(pages: pages)
        edit(&content)
        let url = h.dir.appending(path: "Draft.bookbook", directoryHint: .isDirectory)
        try BookStore.create(content, at: url)
        let document = BookDocument(content: content, store: BookStore(packageURL: url))
        return Setup(h: h, app: h.makeApp(), document: document)
    }

    private func box(of page: PageID, in content: BookContent) -> BoxID {
        content.pages[page]!.images.keys.first!
    }

    private func place(_ page: PageID, in content: inout BookContent) {
        let box = box(of: page, in: content)
        content.pages[page]?.images[box]?.placement = ImagePlacement(versionID: VersionID(), boxAspectWhenPlaced: 1)
    }

    @Test func plan_coversEveryEmptyBox_coverFirst_withDraftItems() throws {
        let s = try setup()
        defer { s.h.tearDown() }
        let content = s.document.content
        let plan = s.app.draftAllPlan(in: s.document)
        #expect(plan.count == 4)
        #expect(plan.targets.map(\.page) == [content.book.coverPageID] + content.book.pageOrder)
        for (item, target) in zip(plan.items, plan.targets) {
            #expect(item.target == .pageBox(target.page, target.box))
            #expect(item.intent.quality == .draft)
            #expect(item.intent.includeStoryText)
            #expect(item.intent.messageText == DraftAllPlanner.messageText)
            #expect(item.intent.model == s.app.defaults.model)
            #expect(item.bookID == s.document.id)
            #expect(item.estimate.amount != nil)
        }
        #expect(plan.items.map(\.display.pageLabel) == ["Cover", "Page 1", "Page 2", "Page 3"])
        #expect(plan.items.allSatisfy { $0.display.boxLabel == "Image 1" && $0.display.bookTitle == "Test" })
        #expect(plan.estimate == CostEstimate.total(plan.items.map(\.estimateIncludingFollowUp)))
        let total = try #require(plan.estimate.amount)
        #expect(total > 0)
        // Nothing appended or enqueued by planning.
        #expect(s.document.content == content)
    }

    @Test func plan_skipsFilledBoxes_andACoverWithoutImageBoxes() throws {
        let s = try setup { content in
            self.place(content.book.pageOrder[1], in: &content)
            // A text-only cover template.
            let cover = Template(name: "Text cover", kind: .cover, boxes: [Fixtures.textBox])
            content.templates[cover.id] = cover
            content.pages[content.book.coverPageID]?.templateID = cover.id
            content.pages[content.book.coverPageID]?.images = [:]
        }
        defer { s.h.tearDown() }
        let order = s.document.content.book.pageOrder
        let plan = s.app.draftAllPlan(in: s.document)
        #expect(plan.targets.map(\.page) == [order[0], order[2]])
        #expect(plan.items.map(\.display.pageLabel) == ["Page 1", "Page 3"])
    }

    @Test func plan_skipsBoxesWithAPendingRequest() async throws {
        let s = try setup()
        defer { s.h.tearDown() }
        let page = s.document.content.book.pageOrder[0]
        s.app.pauseQueue()
        #expect(s.app.generate(prompt: "a fox", quality: .standard, includeStoryText: true, refines: nil,
                               attachedReferences: [], target: .pageBox(page, box(of: page, in: s.document.content)),
                               in: s.document))
        // Pending before the queue's snapshot has it (this launch) and after.
        #expect(!s.app.draftAllPlan(in: s.document).targets.contains { $0.page == page })
        await s.app.queueOperationsSettled()
        await until("snapshot") { s.app.queueSnapshot.entries.count == 1 }
        let plan = s.app.draftAllPlan(in: s.document)
        #expect(plan.count == 3)
        #expect(!plan.targets.contains { $0.page == page })
    }

    @Test func plan_emptyBook_isEmptyWithZeroTotal() throws {
        let s = try setup(pages: 0) { content in
            self.place(content.book.coverPageID, in: &content)
        }
        defer { s.h.tearDown() }
        let plan = s.app.draftAllPlan(in: s.document)
        #expect(plan.count == 0)
        #expect(plan.estimate.amount == 0)
        #expect(!s.app.enqueueDraftAll(plan, in: s.document))
    }

    /// Every pending message is appended, and the queue gets all items in one call: no
    /// published snapshot ever shows only some of them.
    @Test func enqueue_appendsAllMessages_andEnqueuesInOneCall() async throws {
        let s = try setup()
        defer { s.h.tearDown() }
        s.app.pauseQueue()
        await s.app.queueOperationsSettled()
        let counts = Counts()
        let queue = s.app.queue
        let watcher = Task {
            for await snapshot in await queue.subscribe() { await counts.add(snapshot.entries.count) }
        }
        defer { watcher.cancel() }
        await until("watching") { await counts.values.count >= 1 }

        let plan = s.app.draftAllPlan(in: s.document)
        #expect(s.app.enqueueDraftAll(plan, in: s.document))
        await s.app.queueOperationsSettled()
        let snapshot = await queue.snapshot()
        #expect(snapshot.entries.map(\.id) == plan.items.map(\.id))
        await until("published") { await counts.values.last == plan.count }
        #expect(await counts.values.allSatisfy { $0 == 0 || $0 == plan.count })

        let content = s.document.content
        for (item, target) in zip(plan.items, plan.targets) {
            let session = try #require(content.sessions[content.pages[target.page]!.images[target.box]!.sessionID])
            #expect(session.messages.count == 1)
            let message = try #require(session.messages.first)
            #expect(message.id == item.messageID)
            #expect(message.queueItemID == item.id)
            #expect(message.text == DraftAllPlanner.messageText)
            #expect(s.app.status(of: message) == .waiting)
        }

        // Enqueueing the same plan again does nothing; a new plan finds no empty boxes.
        #expect(!s.app.enqueueDraftAll(plan, in: s.document))
        #expect(s.app.draftAllPlan(in: s.document).count == 0)
    }
}

private actor Counts {
    private(set) var values: [Int] = []
    func add(_ value: Int) { values.append(value) }
}
