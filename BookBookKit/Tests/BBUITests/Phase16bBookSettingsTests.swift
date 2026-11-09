import BBAI
import BBAICore
import BBModel
import Foundation
import Testing
@testable import BBUI

@MainActor @Suite struct Phase16bBookSettingsTests {
    private func entry(book: BookID, refines: VersionID? = nil, refs: [VersionRef] = [],
                       kind: QueueJobKind = .image, state: QueueItemState = .waiting) -> QueueEntry {
        let intent = GenerationIntent(messageText: "x", refines: refines, attachedReferences: refs,
                                      provider: .openai, model: "m", quality: .draft)
        let item = QueueItem(bookID: book, target: .pageBox(PageID(), BoxID()), messageID: MessageID(),
                             intent: intent, kind: kind)
        return QueueEntry(item: item, state: state)
    }

    @Test func protectedVersionsCoverRefinesReferencesAndChecked() {
        let book = BookID(), other = BookID()
        let a = VersionID(), b = VersionID(), c = VersionID(), d = VersionID()
        let ref = VersionRef(sessionID: SessionID(), versionID: b)
        let snapshot = QueueSnapshot(entries: [
            entry(book: book, refines: a, refs: [ref]),
            entry(book: book, kind: .consistencyCheck(c)),
            entry(book: other, refines: d),
        ])
        #expect(StorageModel.protectedVersions(in: snapshot, book: book) == [a, b, c])
    }

    @Test func switchWarningCountsActiveAndUndelivered() {
        let book = BookID()
        let snapshot = QueueSnapshot(entries: [
            entry(book: book),
            entry(book: book, state: .running(startedAt: Date(), progress: nil, attempt: 1)),
            entry(book: book, state: .failed(QueueFailure(error: .timeout, report: nil, attempts: 1, failedAt: Date()))),
        ])
        #expect(LibrarySwitchWarning.pendingCount(snapshot) == 2)
        var withUndelivered = snapshot
        withUndelivered.undeliveredCount = 3
        #expect(LibrarySwitchWarning.pendingCount(withUndelivered) == 5)
        #expect(LibrarySwitchWarning.message(count: 0) == nil)
        #expect(LibrarySwitchWarning.message(count: 2)
            == "2 requests are still queued for books in the current library; their pictures will be lost. Switch anyway?")
        #expect(LibrarySwitchWarning.message(count: 1)?.hasPrefix("1 request is") == true)
    }

    @Test func skippedLinesText() {
        #expect(BookSettingsSheet.skippedLinesText(1) == "1 ledger line couldn't be read.")
        #expect(BookSettingsSheet.skippedLinesText(3) == "3 ledger lines couldn't be read.")
    }
}
