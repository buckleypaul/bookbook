import BBModel
import BBStore
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import BBUI

/// Style references go through `ImageImportNormalizer` like every other import: whatever the file
/// (HEIC from an iPhone, a wrong extension, a rotated photo), the stored image is PNG or JPEG with a
/// matching content type, so providers that only take PNG/JPEG/WebP accept it.
@MainActor
struct StyleReferenceImportTests {
    private nonisolated static let heicEncodable: Bool = encode(width: 8, height: 8, as: .heic) != nil

    private func makeDocument() throws -> BookDocument {
        let content = Fixtures.book()
        let url = FileManager.default.temporaryDirectory.appending(path: "StyleRef-\(UUID().uuidString).bookbook")
        try BookStore.create(content, at: url)
        return BookDocument(content: content, store: BookStore(packageURL: url))
    }

    private nonisolated static func encode(width: Int, height: Int, as type: UTType, orientation: Int? = nil) -> Data? {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 0, green: 0.5, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)
        else { return nil }
        let properties = orientation.map { [kCGImagePropertyOrientation: $0] as CFDictionary }
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private func write(_ data: Data, named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString)-\(name)")
        try data.write(to: url)
        return url
    }

    /// The stored file's actual type and pixel size.
    private func stored(_ ref: ImageRef, in document: BookDocument) throws -> (type: String, width: Int, height: Int) {
        let data = try Data(contentsOf: document.store.imageURL(for: ref))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let type = try #require(CGImageSourceGetType(source)) as String
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return (type, image.width, image.height)
    }

    @Test(.enabled(if: heicEncodable, "This machine can't encode HEIC, so there's no HEIC fixture to import"))
    func heic_isStoredAsPNGOrJPEG() async throws {
        let document = try makeDocument()
        defer { try? FileManager.default.removeItem(at: document.store.packageURL) }
        let file = try write(try #require(Self.encode(width: 64, height: 32, as: .heic)), named: "IMG_0001.heic")
        defer { try? FileManager.default.removeItem(at: file) }

        let ref = try await document.storeStyleReference(from: file)

        #expect(["public.png", "public.jpeg"].contains(ref.contentType))
        let image = try stored(ref, in: document)
        #expect(image.type == ref.contentType)
        #expect(image.width == 64 && image.height == 32)
    }

    @Test func wrongExtension_isStoredByItsRealType() async throws {
        let document = try makeDocument()
        defer { try? FileManager.default.removeItem(at: document.store.packageURL) }
        // JPEG bytes named .heic: the extension isn't trusted.
        let file = try write(try #require(Self.encode(width: 20, height: 10, as: .jpeg)), named: "drawing.heic")
        defer { try? FileManager.default.removeItem(at: file) }

        let ref = try await document.storeStyleReference(from: file)

        #expect(ref.contentType == "public.jpeg")
        #expect(try stored(ref, in: document).type == "public.jpeg")
    }

    @Test func rotatedPhoto_isStoredUpright() async throws {
        let document = try makeDocument()
        defer { try? FileManager.default.removeItem(at: document.store.packageURL) }
        let data = try #require(Self.encode(width: 40, height: 20, as: .jpeg, orientation: 6))
        let file = try write(data, named: "photo.jpg")
        defer { try? FileManager.default.removeItem(at: file) }

        let ref = try await document.storeStyleReference(from: file)

        let image = try stored(ref, in: document)
        #expect(image.type == ref.contentType)
        #expect(image.width == 20 && image.height == 40)
    }

    @Test func largePicture_isScaledDown() async throws {
        let document = try makeDocument()
        defer { try? FileManager.default.removeItem(at: document.store.packageURL) }
        let file = try write(try #require(Self.encode(width: 3000, height: 1500, as: .png)), named: "big.png")
        defer { try? FileManager.default.removeItem(at: file) }

        let ref = try await document.storeStyleReference(from: file)

        let image = try stored(ref, in: document)
        #expect(max(image.width, image.height) == ImageImportNormalizer.referencePhotoMaxPixelSize)
    }

    @Test func notAPicture_andRemoteURLs_areRefused() async throws {
        let document = try makeDocument()
        defer { try? FileManager.default.removeItem(at: document.store.packageURL) }
        let file = try write(Data("not a picture".utf8), named: "fake.png")
        defer { try? FileManager.default.removeItem(at: file) }

        await #expect(throws: ImageImportFailure.notAnImage) {
            try await document.storeStyleReference(from: file)
        }
        await #expect(throws: ImageImportFailure.notAFileURL) {
            try await document.storeStyleReference(from: URL(string: "https://example.com/a.png")!)
        }
    }
}
