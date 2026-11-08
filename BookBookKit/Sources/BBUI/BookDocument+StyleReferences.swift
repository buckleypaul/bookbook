import BBModel
import BBStore
import Foundation
import UniformTypeIdentifiers

extension BookDocument {
    /// Copies an image file into the book's `images/` folder and returns its ref. Accepts PNG,
    /// JPEG, HEIC and WebP. Doesn't change the style (the caller sends `.setStyleVisual`).
    func storeStyleReference(from url: URL) async throws -> ImageRef {
        guard isEditable else { throw StoreError.readOnly }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()),
              let identifier = Self.referenceContentType(for: type)
        else { throw StoreError.io("\(url.lastPathComponent) isn't a PNG, JPEG, HEIC or WebP image") }
        return try await store.storeImage(data, contentType: identifier)
    }

    static func referenceContentType(for type: UTType) -> String? {
        if type.conforms(to: .png) { return "public.png" }
        if type.conforms(to: .jpeg) { return "public.jpeg" }
        if type.conforms(to: .heic) { return "public.heic" }
        if type.identifier == "org.webmproject.webp" { return "org.webmproject.webp" }
        return nil
    }
}
