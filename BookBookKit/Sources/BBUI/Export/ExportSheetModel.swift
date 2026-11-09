import BBExport
import BBLayout
import BBModel
import AppKit
import Foundation
import Observation

/// What the export sheet needs from the outside world. The live implementation wraps
/// `BookExporter`, `ExportImagePreparer` and `Preflight`; tests fake it. (A §9, PD §8.8)
@MainActor
public protocol ExportServices: AnyObject {
    /// Plans and assesses images, then runs preflight on the pages `options` will export.
    func runPreflight(for options: ExportOptions) async -> [PreflightIssue]
    func export(_ options: ExportOptions, to url: URL,
                progress: @MainActor (ExportProgress) -> Void) async throws -> ExportResult
    func coverPDF() async throws -> Data
    /// Builds the PDF with `options` and runs the system print dialog.
    func print(_ options: ExportOptions) async throws
    /// The encoded, upscaled image for a soft-image issue (nil if it has no box).
    func upscaledPreviewURL(for issue: PreflightIssue) async throws -> URL?
}

/// Save-panel setup shared by every export-style panel: its own remembered folder (not the
/// font-import panel's), starting in Documents the first time.
@MainActor
enum ExportPanel {
    private static let key = "ExportPanel.lastDirectory"

    static func configure(_ panel: NSSavePanel) {
        panel.identifier = NSUserInterfaceItemIdentifier("export")
        panel.canCreateDirectories = true
        let remembered = UserDefaults.standard.string(forKey: key).map { URL(filePath: $0, directoryHint: .isDirectory) }
        panel.directoryURL = remembered ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }

    static func remember(_ url: URL) {
        UserDefaults.standard.set(url.deletingLastPathComponent().path(percentEncoded: false), forKey: key)
    }
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
    public var outputType: OutputType = .standard { didSet { result = nil } }
    public var sheetSize: SheetSize = .letter { didSet { result = nil } }
    public var includeCover = true { didSet { result = nil; schedulePreflight() } }
    public var limitsRange = false { didSet { result = nil; schedulePreflight() } }
    public var rangeFrom = 1 { didSet { result = nil; schedulePreflight() } }
    public var rangeTo = 1 { didSet { result = nil; schedulePreflight() } }
    public var spreads: SpreadOutput = .singlePages { didSet { result = nil } }

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
    @ObservationIgnored private var preflightTask: Task<Void, Never>?
    @ObservationIgnored private var preflightGeneration = 0
    /// Row labels for `issues`, built once per check (nil until the first check finishes).
    @ObservationIgnored private var pageLabels: [PageID: String]?
    /// Wait after a range or cover change before re-checking.
    @ObservationIgnored var preflightDelay: Duration = .milliseconds(300)

    public init(content: @escaping @MainActor () -> BookContent,
                perform: @escaping @MainActor (BookCommand) -> Bool,
                services: any ExportServices) {
        self.content = content
        self.performCommand = perform
        self.services = services
        rangeTo = max(1, totalPositions)
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
        BookExporter.storyPositions(content(), range: options.pageRange)
            .map { (position: $0.position.position, span: $0.position.span) }
    }

    /// Whether a cover page will be exported (`BookExporter` needs one to exist).
    private var exportsCover: Bool { includeCover && content().coverPage != nil }

    /// Pages that go into the PDF (a booklet counts each position as one page).
    public var selectedPageCount: Int {
        Self.pageCount(story: selectedStory, exportsCover: exportsCover)
    }

    private static func pageCount(story: [(position: Int, span: Int)], exportsCover: Bool) -> Int {
        story.reduce(0) { $0 + $1.span } + (exportsCover ? 1 : 0)
    }

    /// Booklet only: blank pages the export will add (the inside front cover or a parity
    /// blank before an even-starting range, plus padding to a multiple of 4).
    public var predictedBlanks: Int? {
        guard outputType == .booklet else { return nil }
        let story = selectedStory, exportsCover = exportsCover
        let pageCount = Self.pageCount(story: story, exportsCover: exportsCover)
        guard pageCount > 0 else { return nil }
        let blanks = BookletImposition.blanks(contentPages: pageCount, includeCover: exportsCover,
                                              firstStoryPosition: story.first?.position)
        return blanks.leading + blanks.trailing
    }

    public var canExport: Bool {
        !isExporting && !needsBleed && isRangeValid && selectedPageCount > 0
            && hasCheckedPreflight && !isCheckingPreflight
    }

    /// Booklet only: landscape pages stack two to a sheet, so the fold (and the binding) is at the top.
    public var bookletBindsAtTop: Bool {
        let size = content().style.pageSetup.trimSize
        return size.width > size.height
    }

    /// "Cover" or "Page N" for a preflight row.
    public func pageLabel(for issue: PreflightIssue) -> String {
        (pageLabels ?? Self.pageLabels(content()))[issue.page] ?? "Page"
    }

    /// "Cover" or "Page N" for every page, from one layout pass.
    static func pageLabels(_ content: BookContent) -> [PageID: String] {
        var labels: [PageID: String] = [:]
        for slot in PagesOverviewModel.layout(content).pages {
            labels[slot.id] = slot.span > 1 ? "Pages \(slot.position)–\(slot.position + slot.span - 1)"
                                            : "Page \(slot.position)"
        }
        labels[content.book.coverPageID] = "Cover"
        return labels
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

    /// Checks now and waits for the result.
    public func runPreflight() async {
        let task = startPreflight(after: nil)
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    /// Re-checks after a short wait, so dragging a stepper doesn't start a check per step. The
    /// sheet counts as checking meanwhile, which keeps Export off until the list is current.
    func schedulePreflight() {
        startPreflight(after: preflightDelay)
    }

    /// Cancels any check in flight and starts a new one. The generation check stays as a
    /// backstop in case a cancelled check still returns.
    @discardableResult
    private func startPreflight(after delay: Duration?) -> Task<Void, Never> {
        preflightTask?.cancel()
        preflightGeneration += 1
        let mine = preflightGeneration
        isCheckingPreflight = true
        let task = Task { [weak self] in
            if let delay { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self else { return }
            let found = await services.runPreflight(for: options)
            guard !Task.isCancelled, mine == preflightGeneration else { return }   // a newer check owns the state
            pageLabels = Self.pageLabels(content())
            issues = found
            isCheckingPreflight = false
            hasCheckedPreflight = true
        }
        preflightTask = task
        return task
    }

    /// Waits for a scheduled re-check (tests).
    func waitForPreflight() async { await preflightTask?.value }

    // MARK: Actions

    /// Print shop with bleed off: one undoable `setPageSetup`.
    @discardableResult
    public func turnOnBleed() -> Bool {
        var setup = content().style.pageSetup
        guard !setup.bleedEnabled else { return false }
        setup.bleedEnabled = true
        let done = performCommand(.setPageSetup(setup))
        if done { schedulePreflight() }   // soft-image sizes change with bleed
        return done
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
