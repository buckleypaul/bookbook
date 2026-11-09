import AppKit
import BBExport
import BBLayout
import BBModel
import BBStore
import Foundation
import PDFKit
import UniformTypeIdentifiers

/// The real export machinery for one open book: the preparer's cache lives in
/// `~/Library/Caches/BookBook/<bookID>/export/`.
@MainActor
public final class LiveExportServices: ExportServices {
    private let document: BookDocument
    private let preparer: ExportImagePreparer
    private var requests: [BoxImageKey: ImagePreparationRequest] = [:]

    public init(document: BookDocument) {
        self.document = document
        let directory = URL.cachesDirectory
            .appending(path: "BookBook", directoryHint: .isDirectory)
            .appending(path: document.id.rawValue.uuidString, directoryHint: .isDirectory)
            .appending(path: "export", directoryHint: .isDirectory)
        self.preparer = ExportImagePreparer(cacheDirectory: directory)
    }

    func makeExporter() -> BookExporter {
        let store = document.store
        return BookExporter(content: document.content, images: ImageCache(store: store, maxPixelSize: nil),
                            preparer: preparer, imageURL: { store.imageURL(for: $0) })
    }

    public func runPreflight() async -> [PreflightIssue] {
        await runPreflight(for: ExportOptions())
    }

    public func runPreflight(for options: ExportOptions) async -> [PreflightIssue] {
        let content = document.content
        let store = document.store
        let selected = Preflight.exportedPageIDs(content, options: options)
        var all: [ImagePreparationRequest] = []
        for page in [content.coverPage].compactMap({ $0 }) + content.storyPages where selected.contains(page.id) {
            all += ImagePreparationPlanner.requests(
                page: page, in: content,
                imageURL: { store.imageURL(for: $0) },
                pixelSize: { ImagePixelSize.of(url: store.imageURL(for: $0)) })
        }
        var assessments: [BoxImageKey: ImageAssessment] = [:]
        var byKey: [BoxImageKey: ImagePreparationRequest] = [:]
        for request in all {
            assessments[request.key] = await preparer.assess(request)
            byKey[request.key] = request
        }
        requests = byKey
        return Preflight.run(content, assessments: assessments, spelling: SystemSpellingChecker(),
                             pages: selected)
    }

    public func export(_ options: ExportOptions, to url: URL,
                       progress: @MainActor (ExportProgress) -> Void) async throws -> ExportResult {
        let result = try await makeExporter().export(options, to: url, progress: progress)
        await preparer.pruneCache()
        return result
    }

    public func print(_ options: ExportOptions) async throws {
        let (data, _) = try await makeExporter().pdfData(options) { _ in }
        // After the PDF is built, so the window is the one showing now (the sheet may have closed).
        let window = NSApp.keyWindow.map { $0.sheetParent ?? $0 }
        guard let pdf = PDFDocument(data: data),
              let operation = pdf.printOperation(for: .shared, scalingMode: .pageScaleNone, autoRotate: true)
        else { throw ExportError.encodingFailed }
        if let window {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
    }

    public func coverPDF() async throws -> Data {
        try await makeExporter().coverPDFData()
    }

    public func upscaledPreviewURL(for issue: PreflightIssue) async throws -> URL? {
        guard let box = issue.box, let request = requests[BoxImageKey(page: issue.page, box: box)] else { return nil }
        return try await preparer.preparedFileURL(request)
    }
}

/// File ▸ Print… and File ▸ Export Page as Image….
@MainActor
public enum ExportActions {
    /// Prints the whole book as a Standard PDF through the system print panel.
    public static func print(_ document: BookDocument, options: ExportOptions = ExportOptions()) {
        let services = LiveExportServices(document: document)
        Task { @MainActor in
            do { try await services.print(options) } catch is CancellationError {} catch {
                showError("Couldn't print the book", error)
            }
        }
    }

    /// Saves one page (a spread: both halves) as PNG or JPEG at 300 DPI.
    public static func exportPageAsImage(_ document: BookDocument, page: PageID) {
        let panel = NSSavePanel()
        ExportPanel.configure(panel)
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = ExportSheetModel.fileStem(document.content.book.title) + ".png"
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: ["PNG", "JPEG"])
        let handler = FormatPopupHandler(panel: panel)
        popup.target = handler
        popup.action = #selector(FormatPopupHandler.changed(_:))
        let row = NSStackView(views: [NSTextField(labelWithString: "Format:"), popup])
        row.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        panel.accessoryView = row
        let accepted = withExtendedLifetime(handler) { panel.runModal() == .OK }
        guard accepted, let url = panel.url else { return }
        ExportPanel.remember(url)
        let format: BitmapFormat = popup.indexOfSelectedItem == 1 ? .jpeg : .png
        let services = LiveExportServices(document: document)
        Task { @MainActor in
            do {
                try await services.makeExporter().bitmapData(page: page, format: format).write(to: url, options: .atomic)
            } catch {
                showError("Couldn't export the page", error)
            }
        }
    }

    static func showError(_ title: String, _ error: any Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = ExportSheetModel.message(for: error)
        alert.runModal()
    }
}

/// Keeps the save panel's extension in step with the format popup.
@MainActor
private final class FormatPopupHandler: NSObject {
    private weak var panel: NSSavePanel?
    init(panel: NSSavePanel) { self.panel = panel }

    @objc func changed(_ sender: NSPopUpButton) {
        guard let panel else { return }
        let jpeg = sender.indexOfSelectedItem == 1
        panel.allowedContentTypes = [jpeg ? .jpeg : .png]
        let stem = (panel.nameFieldStringValue as NSString).deletingPathExtension
        panel.nameFieldStringValue = stem + (jpeg ? ".jpg" : ".png")
    }
}
