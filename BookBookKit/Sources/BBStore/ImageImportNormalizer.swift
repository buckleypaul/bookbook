import BBModel
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Why a picked file couldn't be brought in as a version.
public enum ImageImportError: Error, Hashable, Sendable {
    /// Not an image ImageIO can read.
    case notAnImage
    /// The picture was readable but couldn't be re-encoded.
    case encodingFailed
}

/// Prepares a user's own picture for the image store (PD §8.6, Phase 8): EXIF orientation is
/// applied to the pixels (and the tag dropped, so every renderer agrees); HEIC, TIFF and other
/// formats become PNG; JPEG stays JPEG (re-encoded at 0.92 only when it needed rotating) and PNG
/// stays PNG. No AppKit.
public enum ImageImportNormalizer {
    public struct Result: Sendable {
        public var data: Data
        /// `public.png` or `public.jpeg` (an `ImageRef.contentType`).
        public var contentType: String
        public var pixelSize: PixelSize

        public init(data: Data, contentType: String, pixelSize: PixelSize) {
            self.data = data
            self.contentType = contentType
            self.pixelSize = pixelSize
        }
    }

    public static let jpegQuality = 0.92

    public static func normalize(_ data: Data) throws(ImageImportError) -> Result {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              CGImageSourceGetCount(source) > 0,
              let typeID = CGImageSourceGetType(source) as String?,
              let type = UTType(typeID), type.conforms(to: .image),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0
        else { throw .notAnImage }

        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let rotates = (2...8).contains(orientation)
        let swapped = (5...8).contains(orientation)
        let upright = swapped ? PixelSize(width: height, height: width) : PixelSize(width: width, height: height)

        // Already in the right shape: keep the bytes.
        if !rotates, type == .png { return Result(data: data, contentType: "public.png", pixelSize: upright) }
        if !rotates, type == .jpeg { return Result(data: data, contentType: "public.jpeg", pixelSize: upright) }

        // The thumbnail path applies the orientation; asking for the full size keeps every pixel.
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary)
        else { throw .notAnImage }

        let asJPEG = type == .jpeg
        let outType = asJPEG ? UTType.jpeg : UTType.png
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, outType.identifier as CFString, 1, nil)
        else { throw .encodingFailed }
        let destinationOptions: [CFString: Any] = asJPEG ? [kCGImageDestinationLossyCompressionQuality: jpegQuality] : [:]
        CGImageDestinationAddImage(destination, image, destinationOptions as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw .encodingFailed }
        return Result(data: output as Data, contentType: asJPEG ? "public.jpeg" : "public.png",
                      pixelSize: PixelSize(width: image.width, height: image.height))
    }
}
