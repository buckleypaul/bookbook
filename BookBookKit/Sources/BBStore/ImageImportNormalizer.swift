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
        let probe = try Probe(data)
        let orientation = (probe.properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let rotates = (2...8).contains(orientation)
        let swapped = (5...8).contains(orientation)
        let upright = swapped ? PixelSize(width: probe.height, height: probe.width)
                              : PixelSize(width: probe.width, height: probe.height)

        // Already in the right shape: keep the bytes.
        if !rotates, probe.type == .png { return Result(data: data, contentType: "public.png", pixelSize: upright) }
        if !rotates, probe.type == .jpeg { return Result(data: data, contentType: "public.jpeg", pixelSize: upright) }

        // Asking for the full size keeps every pixel.
        let image = try probe.uprightImage(maxPixelSize: max(probe.width, probe.height))
        return try encode(image, as: probe.type == .jpeg ? .jpeg : .png)
    }

    /// The longest edge of a stored asset reference photo (PD §8.3), in pixels.
    public static let referencePhotoMaxPixelSize = 1536

    /// An asset's reference photo (PD §8.3): always re-encoded upright, scaled so its longest edge
    /// is at most `maxPixelSize` (never enlarged), with no metadata (camera, capture date and GPS
    /// are dropped, since the photo is sent to the provider). JPEG, or PNG when it has transparency.
    public static func normalizeReferencePhoto(_ data: Data,
                                               maxPixelSize: Int = referencePhotoMaxPixelSize) throws(ImageImportError) -> Result {
        let probe = try Probe(data)
        let image = try probe.uprightImage(maxPixelSize: min(max(probe.width, probe.height), max(1, maxPixelSize)))
        let hasAlpha: Bool = switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
        return try encode(image, as: hasAlpha ? .png : .jpeg)
    }

    /// A readable image's source, type, properties and stored pixel size (before orientation).
    private struct Probe {
        let source: CGImageSource
        let type: UTType
        let properties: [CFString: Any]
        let width: Int
        let height: Int

        init(_ data: Data) throws(ImageImportError) {
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
            self.source = source
            self.type = type
            self.properties = properties
            self.width = width
            self.height = height
        }

        /// The thumbnail path applies the EXIF orientation; its longest edge is `maxPixelSize`.
        func uprightImage(maxPixelSize: Int) throws(ImageImportError) -> CGImage {
            let thumbnailOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary)
            else { throw .notAnImage }
            return image
        }
    }

    /// `image` as PNG, or as JPEG at `jpegQuality`, with no metadata.
    private static func encode(_ image: CGImage, as outType: UTType) throws(ImageImportError) -> Result {
        let asJPEG = outType == .jpeg
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
