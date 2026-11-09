import BBExport
import BBModel
import BBStore
import Foundation
import Testing
@testable import BBUI

@MainActor
final class FakeExportServices: ExportServices {
    var issues: [PreflightIssue] = []
    var exported: [(ExportOptions, URL)] = []
    var printed: [ExportOptions] = []
    func print(_ options: ExportOptions) async throws { printed.append(options) }
    func runPreflight() async -> [PreflightIssue] { issues }
    func export(_ options: ExportOptions, to url: URL,
                progress: @MainActor (ExportProgress) -> Void) async throws -> ExportResult {
        exported.append((options, url))
        progress(ExportProgress(completedUnits: 1, totalUnits: 1))
        return ExportResult(pageCount: 3)
    }
    func coverPDF() async throws -> Data { Data() }
    func upscaledPreviewURL(for issue: PreflightIssue) async throws -> URL? { nil }
}

@MainActor
struct ExportSheetModelTests {
    let story = Template(
        name: "Image above text", kind: .single,
        boxes: [Box(frame: NormalizedRect(x: 0.1, y: 0.1, width: 0.8, height: 0.5), content: .image)])
    let cover = Template(
        name: "Cover", kind: .cover,
        boxes: [Box(frame: NormalizedRect(x: 0, y: 0, width: 1, height: 1), content: .image)])

    func makeModel(extraPages: Int = 0, issues: [PreflightIssue] = []) throws
        -> (ExportSheetModel, BookDocument, UndoManager, FakeExportServices) {
        let content = BookContent.makeNew(title: "Test", storyTemplate: story, coverTemplate: cover,
                                          now: Date(timeIntervalSince1970: 0))
        let url = FileManager.default.temporaryDirectory
            .appending(path: "ExportSheetModelTests-\(UUID().uuidString).bookbook")
        try BookStore.create(content, at: url)
        let document = BookDocument(content: content, store: BookStore(packageURL: url))
        let undo = UndoManager()
        undo.groupsByEvent = false
        document.undoManager = undo
        for _ in 0..<extraPages {
            undo.beginUndoGrouping()
            document.perform(.addPage(index: document.content.book.pageOrder.count, templateID: story.id))
            undo.endUndoGrouping()
        }
        let services = FakeExportServices()
        services.issues = issues
        return (ExportSheetModel(document: document, services: services), document, undo, services)
    }

    func issue(_ kind: PreflightIssue.Kind, _ detail: String = "x") -> PreflightIssue {
        PreflightIssue(kind: kind, page: PageID(), detail: detail)
    }

    @Test func spreadsOptionHiddenForBooklet() throws {
        let (model, _, _, _) = try makeModel()
        #expect(model.showsSpreadsOption)
        model.spreads = .doubleWidth
        #expect(model.options.spreads == .doubleWidth)
        model.outputType = .printShop
        #expect(model.showsSpreadsOption)
        model.outputType = .booklet
        #expect(!model.showsSpreadsOption)
        #expect(model.options.spreads == .singlePages)
        #expect(model.options.kind == .booklet(.letter))
        model.sheetSize = .a4
        #expect(model.options.kind == .booklet(.a4))
    }

    @Test func printShopBlockedWithoutBleed_turnOnBleedIsUndoable() throws {
        let (model, doc, undo, _) = try makeModel()
        model.outputType = .printShop
        #expect(!doc.content.style.pageSetup.bleedEnabled)
        #expect(model.needsBleed)
        #expect(!model.canExport)
        undo.beginUndoGrouping()
        #expect(model.turnOnBleed())
        undo.endUndoGrouping()
        #expect(doc.content.style.pageSetup.bleedEnabled)
        #expect(!model.needsBleed)
        #expect(model.canExport)
        #expect(!model.turnOnBleed())
        undo.undo()
        #expect(!doc.content.style.pageSetup.bleedEnabled)
        #expect(model.needsBleed)
        // Standard and booklet never need bleed.
        model.outputType = .standard
        #expect(model.canExport)
    }

    @Test func primaryTitleFollowsIssues() async throws {
        let (clean, _, _, _) = try makeModel()
        await clean.runPreflight()
        #expect(clean.primaryTitle == "Export…")
        let (dirty, _, _, _) = try makeModel(issues: [issue(.spelling)])
        #expect(dirty.primaryTitle == "Export…")
        await dirty.runPreflight()
        #expect(dirty.primaryTitle == "Export Anyway…")
    }

    @Test func issuesGroupedInKindOrder() async throws {
        let (model, _, _, _) = try makeModel(issues: [
            issue(.missingFont), issue(.spelling, "a"), issue(.emptyImageBox), issue(.spelling, "b"), issue(.softImage),
        ])
        await model.runPreflight()
        let groups = model.issueGroups
        #expect(groups.map(\.kind) == [.emptyImageBox, .spelling, .softImage, .missingFont])
        #expect(groups[1].issues.map(\.detail) == ["a", "b"])
    }

    @Test func predictedBlankCount() throws {
        // Cover + 1 story page = 2 pages -> 2 blanks.
        let (model, _, _, _) = try makeModel()
        #expect(model.predictedBlanks == nil)
        model.outputType = .booklet
        #expect(model.totalPositions == 1)
        #expect(model.predictedBlanks == 2)
        model.includeCover = false
        #expect(model.predictedBlanks == 3)
        #expect(model.offersSeparateCover)
        let (bigger, _, _, _) = try makeModel(extraPages: 3)
        bigger.outputType = .booklet
        #expect(bigger.totalPositions == 4)
        #expect(bigger.predictedBlanks == 3)
        bigger.includeCover = false
        #expect(bigger.predictedBlanks == 0)
        bigger.limitsRange = true
        bigger.rangeFrom = 2
        bigger.rangeTo = 3
        #expect(bigger.options.pageRange == 2...3)
        #expect(bigger.predictedBlanks == 2)
        // Cover + 3 story pages = 4 pages, but the inside front cover blank is needed so
        // story page 1 stays right-hand: 4 + 1 leading + 3 padding.
        let (three, _, _, _) = try makeModel(extraPages: 2)
        three.outputType = .booklet
        #expect(three.totalPositions == 3)
        #expect(three.predictedBlanks == 4)
    }

    @Test func rangeValidation() throws {
        let (model, _, _, _) = try makeModel(extraPages: 2)
        model.limitsRange = true
        model.rangeFrom = 3
        model.rangeTo = 2
        #expect(!model.isRangeValid)
        #expect(!model.canExport)
        model.rangeTo = 9
        #expect(!model.isRangeValid)
        model.rangeTo = 3
        #expect(model.canExport)
    }

    @Test func exportRunsServiceWithOptions() async throws {
        let (model, _, _, services) = try makeModel()
        let url = FileManager.default.temporaryDirectory.appending(path: "x.pdf")
        model.chooseDestination = { _ in url }
        model.includeCover = false
        model.startExport()
        #expect(model.isExporting)
        await model.waitForExport()
        #expect(!model.isExporting)
        #expect(services.exported.count == 1)
        #expect(services.exported[0].0.includeCover == false)
        #expect(services.exported[0].1 == url)
        #expect(model.result?.pageCount == 3)
    }

    @Test func printUsesChosenOptions() async throws {
        let (model, _, _, services) = try makeModel(extraPages: 2, issues: [issue(.spelling)])
        #expect(model.printTitle == "Print…")
        await model.runPreflight()
        #expect(model.printTitle == "Print Anyway…")
        model.outputType = .booklet
        model.sheetSize = .a4
        model.includeCover = false
        model.startPrint()
        await model.waitForExport()
        #expect(services.printed == [ExportOptions(kind: .booklet(.a4), includeCover: false)])
        // Print shop without bleed is blocked, like export.
        model.outputType = .printShop
        model.startPrint()
        #expect(services.printed.count == 1)
    }

    @Test func errorsAreReadable() {
        #expect(ExportSheetModel.message(for: ExportError.bleedRequired).contains("bleed"))
    }
}
