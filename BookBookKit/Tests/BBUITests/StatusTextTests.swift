import BBAI
import BBAICore
import BBModel
import BBStore
import CoreGraphics
import Foundation
import Testing
@testable import BBUI

struct ProviderErrorTextTests {
    @Test func offline() {
        #expect(ProviderErrorText.message(for: .offline) == "Offline — check your internet connection, then try again.")
    }

    @Test func missingAndInvalidKey_pointToSettings() {
        #expect(ProviderErrorText.message(for: .missingKey) == "Add your OpenAI API key in Settings ▸ API Keys.")
        #expect(ProviderErrorText.message(for: .invalidKey(nil)).contains("OpenAI API key in Settings ▸ API Keys."))
    }

    @Test func refused() {
        let error = ProviderError.refused(stage: .input, categories: ["violence"],
                                          ProviderErrorRaw(status: 400, code: "moderation_blocked", body: "{}"))
        #expect(ProviderErrorText.message(for: error)
            == "The request was blocked by the provider's safety system. Try rephrasing.")
    }

    @Test func everyCase_isShortPlainAndHidesProviderWording() {
        let raw = ProviderErrorRaw(status: 500, code: "secret_code", body: "PROVIDER WORDING")
        let all: [ProviderError] = [
            .invalidKey(raw), .missingKey, .verificationRequired(raw), .regionUnsupported(raw), .billing(raw),
            .rateLimited(retryAfter: 3, raw), .refused(stage: .output, categories: [], raw), .noImage(raw),
            .invalidRequest(param: "size", raw), .invalidRequest(param: nil, raw), .modelUnavailable(raw),
            .transient(raw), .offline, .timeout, .cancelled, .unknown(raw),
        ]
        for error in all {
            let text = ProviderErrorText.message(for: error)
            #expect(!text.isEmpty)
            #expect(text.count < 140)
            #expect(!text.contains("PROVIDER WORDING"))
            #expect(!text.contains("secret_code"))
        }
        #expect(ProviderErrorText.message(for: .invalidRequest(param: "size", nil)).contains("(size)"))
    }

    @Test func storeErrors_havePlainText() {
        let errors: [StoreError] = [.notFound("x"), .corrupt("x"), .io("x"), .schemaTooNew(9), .keychain(-25300)]
        for error in errors { #expect(!StoreErrorText.message(for: error).isEmpty) }
    }
}

struct ElapsedTimeTextTests {
    @Test func clock() {
        #expect(ElapsedTimeText.clock(0) == "0:00")
        #expect(ElapsedTimeText.clock(7.9) == "0:07")
        #expect(ElapsedTimeText.clock(65) == "1:05")
        #expect(ElapsedTimeText.clock(-3) == "0:00")
    }

    @Test func progress() {
        #expect(ElapsedTimeText.progress(elapsed: 7, typical: 14) == "0:07 of ~0:14")
        #expect(ElapsedTimeText.progress(elapsed: 7, typical: nil) == "0:07")
        #expect(ElapsedTimeText.progress(elapsed: 7, typical: 0) == "0:07")
        #expect(ElapsedTimeText.progress(elapsed: 14, typical: 14) == "0:14 of ~0:14")
        #expect(ElapsedTimeText.progress(elapsed: 130, typical: 70) == "2:10 (usually ~1:10)")
    }
}

struct MessageStatusTests {
    private let item = QueueItem(bookID: BookID(), target: .pageBox(PageID(), BoxID()), messageID: MessageID(),
                                 intent: GenerationIntent(messageText: "x", provider: .openai, model: "m",
                                                          quality: .standard))

    private func message(queued: Bool, produced: VersionID? = nil) -> Message {
        Message(id: item.messageID, role: .user, text: "x", producedVersion: produced,
                queueItemID: queued ? item.id : nil, createdAt: Fixtures.date)
    }

    private func resolve(_ message: Message, _ state: QueueItemState?, pending: Set<QueueItemID> = [],
                         failures: [MessageID: String] = [:]) -> MessageStatus {
        let snapshot = QueueSnapshot(entries: state.map { [QueueEntry(item: item, state: $0)] } ?? [])
        return MessageStatus.resolve(message, in: item.target.owner, snapshot: snapshot, pendingThisLaunch: pending,
                                     deliveryFailures: failures) { _ in 14 }
    }

    @Test func pictureThatCouldNotBeSaved_isShown() {
        let failures = [item.messageID: "Couldn't save the picture to the book: disk full"]
        #expect(resolve(message(queued: false), nil, failures: failures)
            == .notSaved("Couldn't save the picture to the book: disk full"))
        // Still pending wins; a produced version wins.
        #expect(resolve(message(queued: true), .waiting, failures: failures) == .waiting)
        let version = VersionID()
        #expect(resolve(message(queued: false, produced: version), nil, failures: failures) == .produced(version))
    }

    @Test func pendingStates() {
        #expect(resolve(message(queued: true), .waiting) == .waiting)
        let start = Fixtures.date
        #expect(resolve(message(queued: true), .running(startedAt: start, progress: .sent, attempt: 1))
            == .running(startedAt: start, typicalSeconds: 14))
        #expect(resolve(message(queued: true), .failed(QueueFailure(error: .offline, report: nil, attempts: 1, failedAt: Date()))) == .failed(.offline))
    }

    @Test func pendingButNotInQueue() {
        #expect(resolve(message(queued: true), nil, pending: [item.id]) == .waiting)
        #expect(resolve(message(queued: true), nil) == .interrupted)
    }

    @Test func finished() {
        // Failure delivered: the message's queueItemID is cleared, the queue keeps the failed entry.
        #expect(resolve(message(queued: false), .failed(QueueFailure(error: .missingKey, report: nil, attempts: 1, failedAt: Date()))) == .failed(.missingKey))
        let version = VersionID()
        #expect(resolve(message(queued: false, produced: version), nil) == .produced(version))
        #expect(resolve(message(queued: false), nil) == MessageStatus.none)
    }

    /// Try Again puts a failed item back without restoring the link its delivery cleared: the
    /// message still follows it while it waits and runs again.
    @Test func afterTryAgain_theUnlinkedMessageFollowsItsRequest() {
        let start = Fixtures.date
        #expect(resolve(message(queued: false), .waiting) == .waiting)
        #expect(resolve(message(queued: false), .retrying(attempt: 2, resumesAt: start, lastError: .transient(nil)))
            == .waiting)
        #expect(resolve(message(queued: false), .running(startedAt: start, progress: .sent, attempt: 1))
            == .running(startedAt: start, typicalSeconds: 14))
    }

    /// The match by message ID takes only an image request for the message's own session.
    @Test func unlinkedMatch_ignoresOtherSessionsAndConsistencyChecks() {
        let running = QueueItemState.running(startedAt: Fixtures.date, progress: .sent, attempt: 1)
        // A duplicated page's copy of the message (same ID, another session): the request delivers
        // to the original only.
        let copy = MessageStatus.resolve(message(queued: false), in: .pageBox(PageID(), BoxID()),
                                         snapshot: QueueSnapshot(entries: [QueueEntry(item: item, state: running)]),
                                         pendingThisLaunch: []) { _ in 14 }
        #expect(copy == MessageStatus.none)
        // A consistency check carries its version's message ID: the message still shows its version.
        let version = VersionID()
        var check = item
        check.id = QueueItemID()
        check.kind = .consistencyCheck(version)
        let checked = MessageStatus.resolve(message(queued: false, produced: version), in: item.target.owner,
                                            snapshot: QueueSnapshot(entries: [QueueEntry(item: check, state: running)]),
                                            pendingThisLaunch: []) { _ in 14 }
        #expect(checked == .produced(version))
    }
}

struct VersionDetailsContentTests {
    @Test func generated_showsEverythingSent() {
        let version = Version(image: Fixtures.ref, pixelSize: PixelSize(width: 1024, height: 1536), source: .generated,
                              createdAt: Fixtures.date, provenance: Fixtures.provenance(prompt: "THE EXACT PROMPT"))
        let rows = VersionDetailsContent.rows(for: version) { _ in "DATE" }
        let dict = Dictionary(rows.map { ($0.label, $0.value) }, uniquingKeysWith: { a, _ in a })
        #expect(dict["Provider"] == "OpenAI")
        #expect(dict["Model"] == "gpt-image-2.5-sunburst")
        #expect(dict["Quality"] == "Standard")
        #expect(dict["Output size"] == "1024 × 1536")
        // Equal to the output size, so not listed twice.
        #expect(dict["Image size"] == nil)
        #expect(dict["Prompt sent"] == "THE EXACT PROMPT")
        #expect(dict["Your request"] == "a fox")
        // One row, a "key: value" line per parameter, in a stable (sorted) order.
        #expect(dict["Parameters sent"] == "n: 1\nquality: medium\nsize: 1024x1536")
        #expect(dict["References sent"] == "None")
        #expect(dict["Story text included"] == "Yes")
        #expect(dict["Usage"]?.hasPrefix("Input: 120 text") == true)
        #expect(dict["Usage"]?.contains("Output: ") == true)
        #expect(dict["Usage"]?.contains("4160 image tokens") == true)
        #expect(dict["Date"] == "DATE")
        #expect(dict["Revised prompt"] == nil)
        #expect(!rows.map(\.label).contains { $0.hasPrefix("Parameter ") })
    }

    @Test func modelShowsItsNameAndID() {
        let version = Version(image: Fixtures.ref, pixelSize: PixelSize(width: 1024, height: 1536), source: .generated,
                              createdAt: Fixtures.date, provenance: Fixtures.provenance())
        let rows = VersionDetailsContent.rows(for: version, modelName: { _, _ in "GPT Image 2.5 Sunburst" })
        #expect(rows.first { $0.label == "Model" }?.value == "GPT Image 2.5 Sunburst (gpt-image-2.5-sunburst)")
        #expect(VersionDetailsContent.modelText("x-1", name: "x-1 (custom)") == "x-1 (custom)")
    }

    @Test func revisedPromptAndMissingUsage() {
        var provenance = Fixtures.provenance()
        provenance.usage = nil
        provenance.revisedPrompt = "REVISED"
        provenance.storyTextIncluded = false
        let version = Version(image: Fixtures.ref, pixelSize: PixelSize(width: 1, height: 1), source: .generated,
                              createdAt: Fixtures.date, provenance: provenance)
        let dict = Dictionary(VersionDetailsContent.rows(for: version).map { ($0.label, $0.value) },
                              uniquingKeysWith: { a, _ in a })
        #expect(dict["Usage"] == "Not reported")
        #expect(dict["Revised prompt"] == "REVISED")
        #expect(dict["Story text included"] == "No")
    }

    @Test func imported_hasNoProvenanceRows() {
        let version = Version(image: Fixtures.ref, pixelSize: PixelSize(width: 1, height: 1), source: .imported,
                              createdAt: Fixtures.date)
        let labels = VersionDetailsContent.rows(for: version).map(\.label)
        #expect(labels == ["Source", "Size", "Date"])
    }
}

struct PageListingTests {
    @Test func items_numberStoryPagesInOrder() {
        var content = Fixtures.book(pages: 3)
        let second = content.book.pageOrder[1]
        content.pages[second]?.text[Fixtures.textBox.id] = RichText(plain: "Hello")
        let items = PageListing.items(content)
        #expect(items.map(\.title) == ["Page 1", "Page 2", "Page 3"])
        #expect(items.map(\.id) == content.book.pageOrder)
        #expect(items.map(\.status) == [.empty, .inProgress, .empty])
    }

    @Test func storyTemplate_fromExistingPage_thenPreset_thenAnySingle() {
        let content = Fixtures.book(pages: 1)
        #expect(PageListing.storyTemplateID(in: content, preset: { nil }) == Fixtures.storyTemplate.id)
        var empty = Fixtures.book(pages: 0)
        #expect(PageListing.storyTemplateID(in: empty, preset: { Fixtures.storyTemplate.id }) == Fixtures.storyTemplate.id)
        #expect(PageListing.storyTemplateID(in: empty, preset: { TemplateID() }) == Fixtures.storyTemplate.id)
        empty.templates[Fixtures.storyTemplate.id] = nil
        #expect(PageListing.storyTemplateID(in: empty, preset: { nil }) == nil)
    }

    @Test func selectionAfterDeleting() {
        let content = Fixtures.book(pages: 3)
        let order = content.book.pageOrder
        #expect(PageListing.selectionAfterDeleting(order[1], in: content) == order[2])
        #expect(PageListing.selectionAfterDeleting(order[2], in: content) == order[1])
        let single = Fixtures.book(pages: 1)
        #expect(PageListing.selectionAfterDeleting(single.book.pageOrder[0], in: single) == nil)
    }
}

struct CanvasGeometryTests {
    @Test func transform_fitsAndCentresThePage() {
        let t = CanvasTransform(viewSize: CGSize(width: 1000, height: 840), pageSize: CGSize(width: 612, height: 792),
                                margin: 24)
        #expect(abs(t.scale - 1) < 1e-9)
        #expect(t.origin == CGPoint(x: 194, y: 24))
        let p = t.toPage(CGPoint(x: 194 + 306, y: 24 + 396))
        #expect(abs(p.x - 306) < 1e-9 && abs(p.y - 396) < 1e-9)
        #expect(t.toView(CGRect(x: 10, y: 20, width: 30, height: 40)) == CGRect(x: 204, y: 44, width: 30, height: 40))
    }

    @Test func hitTest_prefersTopmostBox() {
        let a = Box(frame: NormalizedRect(x: 0, y: 0, width: 1, height: 1), content: .image)
        let b = Box(frame: NormalizedRect(x: 0, y: 0, width: 1, height: 1), content: .text(TextBoxStyle()))
        let boxes = [(box: a, rect: CGRect(x: 0, y: 0, width: 100, height: 100)),
                     (box: b, rect: CGRect(x: 50, y: 50, width: 50, height: 50))]
        #expect(CanvasHitTest.box(at: CGPoint(x: 60, y: 60), in: boxes)?.id == b.id)
        #expect(CanvasHitTest.box(at: CGPoint(x: 10, y: 10), in: boxes)?.id == a.id)
        #expect(CanvasHitTest.box(at: CGPoint(x: 200, y: 10), in: boxes) == nil)
    }

    @Test func textRect_insetsByPadding() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 50)
        #expect(CanvasHitTest.textRect(rect, box: Fixtures.textBox) == CGRect(x: 4, y: 4, width: 92, height: 42))
        #expect(CanvasHitTest.textRect(rect, box: Fixtures.imageBox) == rect)
    }
}

@MainActor
struct PDFExportNameTests {
    @Test func defaultFileName() {
        #expect(ExportSheetModel.fileStem("Test") == "Test")
        #expect(ExportSheetModel.fileStem(" a/b:c ") == "a-b-c")
        #expect(ExportSheetModel.fileStem("  ") == "Untitled")
    }
}
