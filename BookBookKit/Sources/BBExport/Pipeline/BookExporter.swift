import BBLayout
import BBModel
import Foundation

// Phase 14 pipeline lane: replace this stub (keep the public signatures).

@MainActor
public final class BookExporter {
    public init(content: BookContent, images: any PageImageSource, preparer: any ImagePreparing,
                imageURL: @escaping @Sendable (ImageRef) -> URL) {}

    public func pdfData(_ options: ExportOptions,
                        progress: @MainActor (ExportProgress) -> Void) async throws -> (Data, ExportResult) {
        fatalError("BookExporter.pdfData not implemented")
    }

    public func export(_ options: ExportOptions, to url: URL,
                       progress: @MainActor (ExportProgress) -> Void) async throws -> ExportResult {
        fatalError("BookExporter.export not implemented")
    }

    public func bitmapData(page: PageID, format: BitmapFormat) async throws -> Data {
        fatalError("BookExporter.bitmapData not implemented")
    }

    public func coverPDFData() async throws -> Data {
        fatalError("BookExporter.coverPDFData not implemented")
    }
}
