import BBModel
import BBStore
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import BBUI

/// Books saved before style references were normalized can hold a HEIC reference, or one whose
/// bytes don't match its `contentType`. Opening the book repairs them to PNG/JPEG (a data repair,
/// not an undoable edit), leaves undecodable ones alone, and doesn't repair a sound book again.
@MainActor
struct StyleReferenceRepairTests {
    private nonisolated static let heicEncodable: Bool = encode(width: 8, height: 8, as: .heic) != nil

    private nonisolated static func encode(width: Int, height: Int, as type: UTType) -> Data? {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 0.4, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// A package whose style references are `files`, written straight into `images/` under the
    /// given content type (as the old import path did).
    private func makeBook(_ files: [(data: Data, contentType: String)]) throws -> (URL, [ImageRef]) {
        var content = Fixtures.book()
        let refs = files.map { file in
            ImageRef(sha256: SHA256.hash(data: file.data).map { String(format: "%02x", $0) }.joined(),
                     contentType: file.contentType)
        }
        content.style.styleReferences = refs
        let url = FileManager.default.temporaryDirectory.appending(path: "Repair-\(UUID().uuidString).bookbook",
                                                                    directoryHint: .isDirectory)
        try BookStore.create(content, at: url)
        let images = url.appending(path: "images", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        for (file, ref) in zip(files, refs) { try file.data.write(to: images.appending(path: ref.fileName)) }
        return (url, refs)
    }

    /// The stored file's real type, sniffed from its bytes.
    private func storedType(_ ref: ImageRef, in url: URL) throws -> String {
        let data = try Data(contentsOf: url.appending(path: "images").appending(path: ref.fileName))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        return try #require(CGImageSourceGetType(source)) as String
    }

    /// The style references saved on disk (read without the lock, so nothing is repaired).
    private func savedReferences(at url: URL) async throws -> [ImageRef] {
        let store = BookStore(packageURL: url)
        await store.setReadOnly()
        return try await store.load().style.styleReferences
    }

    private func expectSound(_ ref: ImageRef, in url: URL) throws {
        #expect(["public.png", "public.jpeg"].contains(ref.contentType))
        #expect(try storedType(ref, in: url) == ref.contentType)
    }

    @Test(.enabled(if: heicEncodable, "This machine can't encode HEIC, so there's no HEIC fixture"))
    func heicReference_isRepairedOnOpen_withoutUndo() async throws {
        let heic = try #require(Self.encode(width: 64, height: 32, as: .heic))
        let png = try #require(Self.encode(width: 10, height: 10, as: .png))
        let (url, refs) = try makeBook([(heic, "public.heic"), (png, "public.png")])
        defer { try? FileManager.default.removeItem(at: url) }

        let document = try await BookDocument.open(at: url)
        let repaired = document.content.style.styleReferences

        #expect(repaired.count == 2)
        try expectSound(repaired[0], in: url)
        #expect(repaired[0] != refs[0])
        #expect(repaired[1] == refs[1], "A sound reference is untouched and keeps its place")
        #expect(try await savedReferences(at: url) == repaired, "The repair is saved")
        // Not an edit: nothing to undo, and no undo record holds image files.
        let undo = UndoManager()
        document.undoManager = undo
        #expect(!undo.canUndo)
        #expect(document.undoImageFileNames.isEmpty)
        await document.close()
    }

    @Test func mislabelledReferences_areRepairedByTheirRealBytes() async throws {
        let tiff = try #require(Self.encode(width: 30, height: 20, as: .tiff))
        let jpeg = try #require(Self.encode(width: 12, height: 8, as: .jpeg))
        let (url, refs) = try makeBook([(tiff, "public.png"), (jpeg, "public.png")])
        defer { try? FileManager.default.removeItem(at: url) }

        let document = try await BookDocument.open(at: url)
        let repaired = document.content.style.styleReferences
        await document.close()

        #expect(repaired.count == 2)
        for ref in repaired { try expectSound(ref, in: url) }
        #expect(Set(repaired).isDisjoint(with: refs))
        #expect(try await savedReferences(at: url) == repaired)
    }

    @Test func undecodableReference_isLeftAlone_andTheBookOpens() async throws {
        let junk = Data("not a picture at all".utf8)
        let jpeg = try #require(Self.encode(width: 12, height: 8, as: .jpeg))
        let (url, refs) = try makeBook([(junk, "public.heic"), (jpeg, "public.png")])
        defer { try? FileManager.default.removeItem(at: url) }

        let document = try await BookDocument.open(at: url)
        let after = document.content.style.styleReferences
        await document.close()

        #expect(after.count == 2)
        #expect(after[0] == refs[0], "Undecodable bytes are kept as they were")
        try expectSound(after[1], in: url)
        #expect(try await savedReferences(at: url) == after)
    }

    @Test func repairedBook_isNotRepairedAgain() async throws {
        let tiff = try #require(Self.encode(width: 30, height: 20, as: .tiff))
        let (url, _) = try makeBook([(tiff, "public.jpeg")])
        defer { try? FileManager.default.removeItem(at: url) }

        let first = try await BookDocument.open(at: url)
        let repaired = first.content.style.styleReferences
        await first.close()
        let styleFile = url.appending(path: "style.json")
        let written = try Data(contentsOf: styleFile)

        let second = try await BookDocument.open(at: url)
        #expect(second.content.style.styleReferences == repaired)
        #expect(await second.store.repairingStyleReferences(in: second.content) == nil)
        await second.close()
        #expect(try Data(contentsOf: styleFile) == written, "style.json isn't rewritten")
    }

    @Test func readOnlyOpen_repairsNothing() async throws {
        let tiff = try #require(Self.encode(width: 30, height: 20, as: .tiff))
        let (url, refs) = try makeBook([(tiff, "public.png")])
        defer { try? FileManager.default.removeItem(at: url) }

        let document = try await BookDocument.open(at: url, readOnly: true)
        #expect(document.content.style.styleReferences == refs)
        #expect(try await savedReferences(at: url) == refs)
    }

    @Test func soundness_sniffsBytesNotLabels() throws {
        let png = try #require(Self.encode(width: 4, height: 4, as: .png))
        let ref = ImageRef(sha256: String(repeating: "a", count: 64), contentType: "public.png")
        #expect(StyleReferenceRepair.isSound(png, as: ref))
        #expect(!StyleReferenceRepair.isSound(png, as: ImageRef(sha256: ref.sha256, contentType: "public.jpeg")))
        #expect(!StyleReferenceRepair.isSound(png, as: ImageRef(sha256: ref.sha256, contentType: "org.webmproject.webp")))
        #expect(!StyleReferenceRepair.isSound(Data("x".utf8), as: ref))
    }
}
