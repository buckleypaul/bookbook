import BBModel
import CoreGraphics
import Foundation

// Phase 11 contract: region-edit image operations (A §7.6). Pure functions, no UI, no I/O beyond
// encoding/decoding bytes. Safe to call off the main actor.

/// The user's region drawing, in **image pixel coordinates** of the base version (origin top-left,
/// y down), replayed in order onto an all-black ("keep") mask. White = edit area.
public struct RegionMaskDrawing: Hashable, Codable, Sendable {
    public enum Operation: Hashable, Codable, Sendable {
        /// A round-capped, round-joined stroke through `points` with the given diameter in pixels.
        /// `erase` paints black (keep) instead of white (edit). A single point is a dot.
        case brush(points: [CGPoint], diameter: Double, erase: Bool)
        /// A closed polygon (non-zero fill). `erase` removes it from the edit area.
        case lasso(points: [CGPoint], erase: Bool)
        /// Swaps edit and keep for everything drawn so far.
        case invert
    }

    public var pixelSize: PixelSize
    public var operations: [Operation]

    public init(pixelSize: PixelSize, operations: [Operation] = []) {
        self.pixelSize = pixelSize
        self.operations = operations
    }

    /// True when no operation has been recorded (the editor disables Generate).
    public var isEmpty: Bool { operations.isEmpty }
}

/// An 8-bit single-channel mask at a fixed pixel size: 255 = edit, 0 = keep. Row-major, top row first.
public struct RegionMask: Hashable, Sendable {
    public var pixelSize: PixelSize
    /// `pixelSize.width * pixelSize.height` bytes.
    public var bytes: [UInt8]

    public init(pixelSize: PixelSize, bytes: [UInt8]) {
        precondition(bytes.count == pixelSize.width * pixelSize.height, "RegionMask byte count")
        self.pixelSize = pixelSize
        self.bytes = bytes
    }

    /// True when no pixel is marked for editing.
    public var isEmpty: Bool { !bytes.contains { $0 != 0 } }
}

public enum ImageOpsError: Error, Equatable, Sendable {
    case undecodableImage
    case sizeMismatch(expected: PixelSize, actual: PixelSize)
    case encodingFailed
}

/// Mask rasterisation, wire encoding, feathered local composite and black-fill detection.
public enum ImageOps {
    /// Feather width (px) of the local composite (A §7.6: about 8 px).
    public static let defaultFeatherPixels: Double = 8

    /// Rasterises `drawing` at its full pixel size (antialiased; values between 0 and 255 on edges).
    public static func rasterize(_ drawing: RegionMaskDrawing) -> RegionMask {
        preconditionFailure("Phase 11 lane: ImageOps.rasterize")
    }

    /// The user's mask as an 8-bit grayscale PNG (white = edit), stored in the book as `regionMask`.
    public static func grayscalePNG(_ mask: RegionMask) throws(ImageOpsError) -> Data {
        preconditionFailure("Phase 11 lane: ImageOps.grayscalePNG")
    }

    /// Decodes a stored grayscale mask PNG back into a `RegionMask`.
    public static func decodeMask(_ png: Data) throws(ImageOpsError) -> RegionMask {
        preconditionFailure("Phase 11 lane: ImageOps.decodeMask")
    }

    /// The OpenAI wire mask (SP-4 polarity): RGBA PNG at the mask's size, alpha 0 where the mask is
    /// edit (> 127), alpha 255 elsewhere. RGB is black.
    public static func providerMaskPNG(_ mask: RegionMask) throws(ImageOpsError) -> Data {
        preconditionFailure("Phase 11 lane: ImageOps.providerMaskPNG")
    }

    /// Blends `edited` into `original` through `mask`, feathered by `featherPixels`: output pixels
    /// are exactly the original's wherever the feathered mask is 0 (further than the feather band
    /// from the edit area), and the edited image's wherever it's 255. `edited` is resampled to the
    /// original's size if the provider returned another size. Returns PNG data at the original's size.
    public static func composite(original: Data, edited: Data, mask: RegionMask,
                                 featherPixels: Double = defaultFeatherPixels) throws(ImageOpsError) -> Data {
        preconditionFailure("Phase 11 lane: ImageOps.composite")
    }

    /// The fraction (0...1) of edit-area pixels (mask > 127) in `image` that are near-black
    /// (max channel ≤ 16). Used to detect SP-4's "black hole" failure.
    public static func blackFillFraction(of image: Data, in mask: RegionMask) throws(ImageOpsError) -> Double {
        preconditionFailure("Phase 11 lane: ImageOps.blackFillFraction")
    }
}
