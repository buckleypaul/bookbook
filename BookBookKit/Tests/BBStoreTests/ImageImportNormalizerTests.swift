import BBModel
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import BBStore

struct ImageImportNormalizerTests {
    /// A solid-colour image built at runtime (no fixture files).
    private static func makeImage(width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    private static func encode(_ image: CGImage, as type: UTType, orientation: Int? = nil) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)
        else { return nil }
        var properties: [CFString: Any] = [:]
        if let orientation { properties[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    private static func properties(of data: Data) -> [CFString: Any] {
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
    }

    static let heicEncodable: Bool = encode(makeImage(width: 8, height: 8), as: .heic) != nil

    @Test func exifRotatedJPEG_becomesUprightJPEGWithoutOrientation() throws {
        // Stored 40 wide x 20 tall, tagged "rotate 90 clockwise" (6): displays 20 x 40.
        let jpeg = try #require(Self.encode(Self.makeImage(width: 40, height: 20), as: .jpeg, orientation: 6))
        let result = try ImageImportNormalizer.normalize(jpeg)
        #expect(result.contentType == "public.jpeg")
        #expect(result.pixelSize == PixelSize(width: 20, height: 40))
        let out = Self.properties(of: result.data)
        #expect(out[kCGImagePropertyPixelWidth] as? Int == 20)
        #expect(out[kCGImagePropertyPixelHeight] as? Int == 40)
        #expect((out[kCGImagePropertyOrientation] as? Int ?? 1) == 1)
    }

    @Test func uprightJPEG_keepsItsBytes() throws {
        let jpeg = try #require(Self.encode(Self.makeImage(width: 30, height: 10), as: .jpeg))
        let result = try ImageImportNormalizer.normalize(jpeg)
        #expect(result.data == jpeg)
        #expect(result.contentType == "public.jpeg")
        #expect(result.pixelSize == PixelSize(width: 30, height: 10))
    }

    @Test func png_staysPNG_andTIFFBecomesPNG() throws {
        let image = Self.makeImage(width: 12, height: 9)
        let png = try #require(Self.encode(image, as: .png))
        let fromPNG = try ImageImportNormalizer.normalize(png)
        #expect(fromPNG.data == png)
        #expect(fromPNG.contentType == "public.png")

        let tiff = try #require(Self.encode(image, as: .tiff))
        let fromTIFF = try ImageImportNormalizer.normalize(tiff)
        #expect(fromTIFF.contentType == "public.png")
        #expect(fromTIFF.pixelSize == PixelSize(width: 12, height: 9))
        #expect(CGImageSourceGetType(CGImageSourceCreateWithData(fromTIFF.data as CFData, nil)!) as String? == "public.png")
    }

    @Test(.enabled(if: heicEncodable, "This machine can't encode HEIC, so there's no HEIC fixture to import"))
    func heic_becomesPNG() throws {
        let heic = try #require(Self.encode(Self.makeImage(width: 64, height: 32), as: .heic))
        let result = try ImageImportNormalizer.normalize(heic)
        #expect(result.contentType == "public.png")
        #expect(result.pixelSize == PixelSize(width: 64, height: 32))
        #expect(CGImageSourceGetType(CGImageSourceCreateWithData(result.data as CFData, nil)!) as String? == "public.png")
    }

    @Test func nonImage_isRejected() {
        #expect(throws: ImageImportError.notAnImage) { try ImageImportNormalizer.normalize(Data("hello".utf8)) }
        #expect(throws: ImageImportError.notAnImage) { try ImageImportNormalizer.normalize(Data()) }
    }
}
