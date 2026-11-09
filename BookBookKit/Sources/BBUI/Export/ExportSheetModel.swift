import BBExport
import BBLayout
import BBModel
import Foundation
import Observation

/// What the export sheet needs from the outside world. The live implementation wraps
/// `BookExporter`, `ExportImagePreparer` and `Preflight`; tests fake it. (A §9, PD §8.8)
@MainActor
public protocol ExportServices: AnyObject {
    /// Plans and assesses images, then runs preflight on the current book.
    func runPreflight() async -> [PreflightIssue]
    func export(_ options: ExportOptions, to url: URL,
                progress: @MainActor (ExportProgress) -> Void) async throws -> ExportResult
    func coverPDF() async throws -> Data
    /// Builds the PDF with `options` and runs the system print dialog.
    func print(_ options: ExportOptions) async throws
    /// The encoded, upscaled image for a soft-image issue (nil if it has no box).
    func upscaledPreviewURL(for issue: PreflightIssue) async throws -> URL?
}

/// State and rules behind the export sheet. No views; every outside effect goes through
/// closures or `ExportServices`.
@MainActor @Observable
public final class ExportSheetModel {
    public enum OutputType: String, CaseIterable, Identifiable, Sendable {
        case standard, printShop, booklet
        public var id: Self { self }
        public var title: String {
            switch self {
            case .standard: "Standard"
            case .printShop: "Print shop"
            case .booklet: "Booklet"
            }
        }
    }

    // Options
    public var outputType: OutputType = .standard
    public var sheetSize: SheetSize = .letter
    public var includeCover = true
    public var limitsRange = false
    public var rangeFrom = 1
    public var rangeTo = 1
    public var spreads: SpreadOutput = .singlePages

    // Preflight
    public private(set) var issues: [PreflightIssue] = []
    public private(set) var isCheckingPreflight = false
    public private(set) var hasCheckedPreflight = false

    // Export
    public private(set) var isExporting = false
    public private(set) var progress: ExportProgress?
    public private(set) var result: ExportResult?
    public var errorMessage: String?

    @ObservationIgnored private let content: @MainActor () -> BookContent
    @ObservationIgnored private let performCommand: @MainActor (BookCommand) -> Bool
    @ObservationIgnored let services: any ExportServices
    /// Asks for the destination (the view runs an NSSavePanel). Nil = cancelled.
    @ObservationIgnored public var chooseDestination: @MainActor (_ suggestedName: String) -> URL? = { _ in nil }
    @ObservationIgnored private var task: Task<Void, Never>?

    public init(content: @escaping @MainActor () -> BookContent,
                perform: @escaping @MainActor (BookCommand) -> Bool,
                services: any ExportServices) {
        self.content = content
        self.performCommand = perform
        self.services = services
        let total = PagesOverviewModel.layout(content()).pages.reduce(0) { $0 + $1.span }
        rangeTo = max(1, total)
    }

    public convenience init(document: BookDocument, services: any ExportServices) {
        self.init(content: { document.content },
                  perform: { document.perform($0) }, services: services)
    }

    // MARK: Derived options

    /// Reading positions in the story pages (a spread takes two).
    public var totalPositions: Int {
        PagesOverviewModel.layout(content()).pages.reduce(0) { $0 + $1.span }
    }

    public var hasSpreads: Bool { PagesOverviewModel.entries(content()).contains { $0.isSpread } }

    public var showsSpreadsOption: Bool { outputType != .booklet }

    public var bleedEnabled: Bool { content().style.pageSetup.bleedEnabled }

    /// Print shop needs bleed on (`ExportError.bleedRequired` otherwise).
    public var needsBleed: Bool { outputType == .printShop && !bleedEnabled }

    public var kind: ExportKind {
        switch outputType {
        case .standard: .standard
        case .printShop: .printShop
        case .booklet: .booklet(sheetSize)
        }
    }

    public var options: ExportOptions {
        ExportOptions(kind: kind, includeCover: includeCover,
                      pageRange: limitsRange ? rangeFrom...max(rangeFrom, rangeTo) : nil,
                      spreads: showsSpreadsOption ? spreads : .singlePages)
    }

    public var isRangeValid: Bool {
        !limitsRange || (rangeFrom >= 1 && rangeFrom <= rangeTo && rangeTo <= totalPositions)
    }

    /// Story pages the export will include: a range that cuts a spread is widened to the
    /// whole spread, exactly as `BookExporter` does.
    private var selectedStory: [(position: Int, span: Int)] {
        let layout = PagesOverviewModel.layout(content()).pages.map { (position: $0.position, span: $0.span) }
        return PageRangeWidening.selected(layout, in: limitsRange ? rangeFrom...max(rangeFrom, rangeTo) : nil)
    }

    /// Whether a cover page will be exported (`BookExporter` needs one to exist).
    private var exportsCover: Bool { includeCover && content().coverPage != nil }

    /// Pages that go into the PDF (a booklet counts each position as one page).
    public var selectedPageCount: Int {
        selectedStory.reduce(0) { $0 + $1.span } + (exportsCover ? 1 : 0)
    }

    /// Booklet only: blank pages the export will add (the inside front cover or a parity
    /// blank before an even-starting range, plus padding to a multiple of 4).
    public var predictedBlanks: Int? {
        guard outputType == .booklet, selectedPageCount > 0 else { return nil }
        let blanks = BookletImposition.blanks(contentPages: selectedPageCount, includeCover: exportsCover,
                                              firstStoryPosition: selectedStory.first?.position)
        return blanks.leading + blanks.trailing
    }

    public var canExport: Bool {
        !isExporting && !needsBleed && isRangeValid && selectedPageCount > 0
    }

    public var offersSeparateCover: Bool { outputType == .booklet && !includeCover }

    // MARK: Preflight

    /// Issues grouped by kind, in `Kind` order; each group keeps reading order.
    public var issueGroups: [(kind: PreflightIssue.Kind, issues: [PreflightIssue])] {
        PreflightIssue.Kind.allCases.compactMap { kind in
            let rows = issues.filter { $0.kind == kind }
            return rows.isEmpty ? nil : (kind, rows)
        }
    }

    public var primaryTitle: String { issues.isEmpty ? "Export…" : "Export Anyway…" }

    public var printTitle: String { issues.isEmpty ? "Print…" : "Print Anyway…" }

    public func runPreflight() async {
        isCheckingPreflight = true
        issues = await services.runPreflight()
        isCheckingPreflight = false
        hasCheckedPreflight = true
    }

    // MARK: Actions

    /// Print shop with bleed off: one undoable `setPageSetup`.
    @discardableResult
    public func turnOnBleed() -> Bool {
        var setup = content().style.pageSetup
        guard !setup.bleedEnabled else { return false }
        setup.bleedEnabled = true
        return performCommand(.setPageSetup(setup))
    }

    public func suggestedFileName(base: String) -> String {
        var name = Self.fileStem(base)
        switch outputType {
        case .standard: break
        case .printShop: name += " (print shop)"
        case .booklet: name += " (booklet)"
        }
        return name + ".pdf"
    }

    /// Asks for a destination, then exports in a task. The UI stays usable meanwhile.
    public func startExport() {
        guard canExport else { return }
        guard let url = chooseDestination(suggestedFileName(base: content().book.title)) else { return }
        let options = options
        isExporting = true
        progress = ExportProgress(completedUnits: 0, totalUnits: 1)
        result = nil
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let outcome = try await services.export(options, to: url) { [weak self] in self?.progress = $0 }
                result = outcome
            } catch is CancellationError {
                // Cancelled by the user: nothing to report.
            } catch {
                errorMessage = Self.message(for: error)
            }
            isExporting = false
            progress = nil
            task = nil
        }
    }

    /// Prints with the sheet's current options (any output type), after the same checks as export.
    public func startPrint() {
        guard canExport else { return }
        let options = options
        isExporting = true
        progress = ExportProgress(completedUnits: 0, totalUnits: 1)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await services.print(options)
            } catch is CancellationError {
            } catch {
                errorMessage = Self.message(for: error)
            }
            isExporting = false
            progress = nil
            task = nil
        }
    }

    public func cancelExport() { task?.cancel() }

    /// Waits for a running export (tests).
    func waitForExport() async { await task?.value }

    public func exportCoverSeparately() {
        guard let url = chooseDestination(suggestedFileName(base: content().book.title + " cover")) else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await services.coverPDF().write(to: url, options: .atomic)
            } catch {
                errorMessage = Self.message(for: error)
            }
        }
    }

    /// A title made safe for a file name.
    public static func fileStem(_ title: String) -> String {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return name.isEmpty ? "Untitled" : name
    }

    public static func message(for error: any Error) -> String {
        switch error as? ExportError {
        case .bleedRequired?: "Print shop export needs bleed. Turn on bleed, then try again."
        case .noPages?: "There are no pages to export in that selection."
        case .contextCreationFailed?: "BookBook couldn't create a page to draw on."
        case .imageUnreadable?: "An image in the book couldn't be read."
        case .encodingFailed?: "The PDF couldn't be written."
        case nil: error.localizedDescription
        }
    }
}
