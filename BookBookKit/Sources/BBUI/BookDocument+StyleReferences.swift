import BBModel
import BBStore
import Foundation

extension BookDocument {
    /// Copies an image file into the book's `images/` folder and returns its ref. Accepts any
    /// picture ImageIO reads (PNG, JPEG, HEIC, WebP, ...), whatever its extension: it's read off the
    /// main actor and normalized like a reference photo (upright, scaled down, metadata dropped, since
    /// it's sent to the provider), so it's always stored as PNG or JPEG. Doesn't change the style (the
    /// caller sends `.setStyleVisual`). Throws `ImageImportFailure`.
    func storeStyleReference(from url: URL) async throws -> ImageRef {
        guard url.isFileURL else { throw ImageImportFailure.notAFileURL }
        guard isEditable else { throw ImageImportFailure.readOnly }
        return try await readAndStore(url, asReferencePhoto: true).0
    }
}
