import BBAI
import BBAICore
import BBModel
import Foundation
import Testing
@testable import BBUI

@Suite struct QueueRowTests {
    private func entry(_ state: QueueItemState, estimate: CostEstimate = .unknown) -> QueueEntry {
        let intent = GenerationIntent(messageText: "a fox", provider: .openai, model: "m", quality: .draft)
        let item = QueueItem(bookID: BookID(), target: .pageBox(PageID(), BoxID()), messageID: MessageID(),
                             intent: intent, estimate: estimate,
                             display: QueueItemDisplay(bookTitle: "Fox Book", pageLabel: "Page 3", boxLabel: "Image 1"))
        return QueueEntry(item: item, state: state)
    }

    private let failure = QueueFailure(error: .timeout, report: nil, attempts: 4, failedAt: Date())

    @Test func actionsPerState() {
        #expect(QueueRowModel(entry: entry(.waiting)).actions == [.remove])
        #expect(QueueRowModel(entry: entry(.waiting)).canReorder)
        let running = QueueRowModel(entry: entry(.running(startedAt: Date(), progress: nil, attempt: 1)))
        #expect(running.actions == [.cancel])
        #expect(!running.canReorder)
        let retrying = QueueRowModel(entry: entry(.retrying(attempt: 2, resumesAt: Date(), lastError: .timeout)))
        #expect(retrying.actions == [.remove])
        #expect(!retrying.canReorder)
        let failed = QueueRowModel(entry: entry(.failed(failure)))
        #expect(failed.actions == [.remove, .retry])
        #expect(failed.isFailed)
    }

    @Test func rowLabels() {
        let model = QueueRowModel(entry: entry(.waiting, estimate: CostEstimate(amount: Decimal(string: "0.07")!)))
        #expect(model.title == "Fox Book")
        #expect(model.location == "Page 3 · Image 1")
        #expect(model.estimateText == "about $0.07")
    }

    @Test func stateText() {
        let now = Date(timeIntervalSince1970: 1000)
        #expect(QueueRowModel.stateText(.waiting, now: now, typical: nil, headline: nil) == "Waiting")
        #expect(QueueRowModel.stateText(.running(startedAt: now.addingTimeInterval(-42), progress: nil, attempt: 1),
                                        now: now, typical: 70, headline: nil) == "Generating… 0:42 of ~1:10")
        #expect(QueueRowModel.stateText(.running(startedAt: now.addingTimeInterval(-5), progress: nil, attempt: 2),
                                        now: now, typical: nil, headline: nil) == "Generating… 0:05 (attempt 2 of 4)")
        #expect(QueueRowModel.stateText(.retrying(attempt: 2, resumesAt: now.addingTimeInterval(11.2), lastError: .timeout),
                                        now: now, typical: nil, headline: nil) == "Retrying in 12 s (attempt 2 of 4)")
        #expect(QueueRowModel.stateText(.failed(failure), now: now, typical: nil, headline: "Blocked by safety")
                == "Blocked by safety")
        #expect(QueueRowModel.stateText(.failed(failure), now: now, typical: nil, headline: nil) == "Failed")
    }

    @Test func bannerText() {
        #expect(QueueBannerModel(pause: nil) == nil)
        #expect(QueueBannerModel(pause: .restored(count: 3))?.text == "3 requests from last time are paused.")
        #expect(QueueBannerModel(pause: .restored(count: 1))?.text == "1 request from last time is paused.")
        #expect(QueueBannerModel(pause: .restored(count: 2))?.offersResume == true)
        let offline = QueueBannerModel(pause: .offline)
        #expect(offline?.text == "You're offline. Queued requests will run when the network returns.")
        #expect(offline?.offersResume == false)
        #expect(QueueBannerModel(pause: .user)?.offersResume == true)
    }

    @Test func badgeCountsLiveItemsOnly() {
        let snapshot = QueueSnapshot(entries: [
            entry(.running(startedAt: Date(), progress: nil, attempt: 1)),
            entry(.waiting),
            entry(.failed(failure)),
        ], undeliveredCount: 2)
        let badge = QueueBadgeModel(snapshot: snapshot)
        #expect(badge.count == 2)
        #expect(badge.running != nil)
        #expect(!badge.isHidden)
        #expect(QueueBadgeModel(snapshot: QueueSnapshot()).isHidden)
        #expect(snapshot.undeliveredText == "2 results waiting for a locked book")
        #expect(QueueSnapshot().undeliveredText == nil)
    }
}
