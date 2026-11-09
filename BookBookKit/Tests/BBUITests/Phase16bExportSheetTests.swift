import BBExport
import BBModel
import BBStore
import Foundation
import Testing
@testable import BBUI

@MainActor
final class RecordingServices: ExportServices {
    var preflightOptions: [ExportOptions] = []
    var gate: CheckedContinuation<Void, Never>?
    func runPreflight() async -> [PreflightIssue] { [] }
    func runPreflight(for options: ExportOptions) async -> [PreflightIssue] {
        preflightOptions.append(options)
        return []
    }
    func print(_ options: ExportOptions) async throws {}
    func export(_ options: ExportOptions, to url: URL,
                progress: @MainActor (ExportProgress) -> Void) async throws -> ExportResult {
        ExportResult(pageCount: 2)
    }
    func coverPDF() async throws -> Data { Data() }
    func upscaledPreviewURL(for issue: PreflightIssue) async throws -> URL? { nil }
}

@MainActor
struct Phase16bExportSheetTests {
    let story = Template(name: "S", kind: .single,
                         boxes: [Box(frame: NormalizedRect(x: 0.1, y: 0.1, width: 0.8, height: 0.5), content: .image)])
    let cover = Template(name: "C", kind: .cover,
                         boxes: [Box(frame: NormalizedRect(x: 0, y: 0, width: 1, height: 1), content: .image)])

    func makeModel() throws -> (ExportSheetModel, BookDocument, RecordingServices) {
        let content = BookContent.makeNew(title: "T", storyTemplate: story, coverTemplate: cover, storyPageCount: 3,
                                          now: Date(timeIntervalSince1970: 0))
        let url = FileManager.default.temporaryDirectory.appending(path: "P16b-\(UUID().uuidString).bookbook")
        try BookStore.create(content, at: url)
        let document = BookDocument(content: content, store: BookStore(packageURL: url))
        let undo = UndoManager()
        undo.groupsByEvent = false
        document.undoManager = undo
        let services = RecordingServices()
        let model = ExportSheetModel(document: document, services: services)
        model.preflightDelay = .milliseconds(1)
        return (model, document, services)
    }

    @Test func cannotExportBeforePreflightFinishes() async throws {
        let (model, _, _) = try makeModel()
        #expect(!model.canExport)
        await model.runPreflight()
        #expect(model.canExport)
    }

    @Test func rangeAndCoverChangesRerunPreflightWithOptions() async throws {
        let (model, _, services) = try makeModel()
        await model.runPreflight()
        model.limitsRange = true
        model.rangeFrom = 2
        model.rangeTo = 2
        #expect(!model.canExport)   // re-checking
        await model.waitForPreflight()
        #expect(services.preflightOptions.last?.pageRange == 2...2)
        model.includeCover = false
        await model.waitForPreflight()
        #expect(services.preflightOptions.last?.includeCover == false)
        #expect(model.canExport)
    }

    @Test func turnOnBleedRerunsPreflight() async throws {
        let (model, _, services) = try makeModel()
        model.outputType = .printShop
        await model.runPreflight()
        let before = services.preflightOptions.count
        #expect(model.turnOnBleed())
        await model.waitForPreflight()
        #expect(services.preflightOptions.count == before + 1)
    }

    @Test func optionChangesClearTheResult() async throws {
        let (model, _, _) = try makeModel()
        await model.runPreflight()
        model.chooseDestination = { _ in FileManager.default.temporaryDirectory.appending(path: "x.pdf") }
        model.startExport()
        await model.waitForExport()
        #expect(model.result != nil)
        model.spreads = .doubleWidth
        #expect(model.result == nil)
    }

    @Test func rowsNameTheirPage() throws {
        let (model, document, _) = try makeModel()
        let c = document.content
        let cover = PreflightIssue(kind: .emptyImageBox, page: c.book.coverPageID, detail: "x")
        let second = PreflightIssue(kind: .emptyImageBox, page: c.storyPages[1].id, detail: "x")
        #expect(model.pageLabel(for: cover) == "Cover")
        #expect(model.pageLabel(for: second) == "Page 2")
    }

    @Test func bookletCaptionKnowsWhenItBindsAtTop() throws {
        let (model, document, _) = try makeModel()
        #expect(!model.bookletBindsAtTop)
        var setup = document.content.style.pageSetup
        setup.trimSize = PointSize(width: setup.trimSize.height, height: setup.trimSize.width)
        document.perform(.setPageSetup(setup))
        #expect(model.bookletBindsAtTop)
    }
}
