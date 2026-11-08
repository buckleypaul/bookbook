import BBLayout
import BBModel
import Foundation

// Owned by the Layout lane. Contract stub: signatures are frozen, bodies are placeholders.

/// File ▸ Export PDF… (Standard) for the slice: story pages in order at trim size, fonts
/// embedded, text kept as real text (A §9.1, thin). The cover is left out until Phase 5.
@MainActor
public enum PDFExporter {
    public static func exportStandard(_ content: BookContent, images: any PageImageSource, to url: URL) throws {
        fatalError("Phase 2 Layout lane: not implemented")
    }

    /// Same, into memory (tests).
    public static func standardPDFData(_ content: BookContent, images: any PageImageSource) throws -> Data {
        fatalError("Phase 2 Layout lane: not implemented")
    }
}
