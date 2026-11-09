import CoreGraphics
import CoreImage
import Foundation
import ImageIO

public enum ImagePixelSize {
    /// Pixel size from the file's properties, without decoding. EXIF orientations 5–8 (which
    /// rotate by 90°) swap the axes, so the size matches what `ImageFiles.decodeOriented` returns.
    public static func of(url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              w > 0, h > 0 else { return nil }
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return (5...8).contains(orientation) ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }
}

/// The space to render an image into with Core Image's RGBA8 output: the image's own space when
/// it is RGB, otherwise (gray, CMYK, Lab, missing) sRGB, since those can't back an RGBA8 render.
func renderingColorSpace(for image: CGImage) -> CGColorSpace {
    if let space = image.colorSpace, space.model == .rgb { return space }
    return CGColorSpace(name: CGColorSpace.sRGB)!
}

enum ImageFiles {
    /// Decode now, not lazily on first draw (which would land on the main actor).
    static var immediate: CFDictionary { [kCGImageSourceShouldCacheImmediately: true] as CFDictionary }

    static func decode(url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, immediate)
    }

    /// Decodes and applies the EXIF orientation, if any.
    static func decodeOriented(url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, immediate) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = (props?[kCGImagePropertyOrientation] as? NSNumber)?.int32Value ?? 1
        guard orientation != 1 else { return image }
        let oriented = CIImage(cgImage: image).oriented(forExifOrientation: orientation)
        let space = renderingColorSpace(for: image)
        return CIContext().createCGImage(oriented, from: oriented.extent, format: .RGBA8, colorSpace: space)
    }
}
