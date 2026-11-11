import BBModel
import Foundation
import ImageIO

/// Reads pixel dimensions from an image header (ImageIO), without decoding. Shared by the
/// assembler (sizes the book doesn't know) and the adapters (sizes of returned images).
public enum ImageHeader {
    /// nil when the bytes aren't a readable image or report no positive size.
    public static func pixelSize(of data: Data) -> PixelSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else { return nil }
        return PixelSize(width: width, height: height)
    }
}
