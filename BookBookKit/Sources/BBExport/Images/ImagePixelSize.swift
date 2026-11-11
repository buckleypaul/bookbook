import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Synchronization

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

/// Shared Core Image contexts. A `CIContext` is costly to create and safe to use from several
/// threads at once, so export keeps one per working colour space instead of one per image.
enum CoreImageContexts {
    /// Default options: for orientation fixes, which don't filter.
    static let standard = CIContext()

    /// Distinct rendering spaces are few (sRGB, Display P3, the odd embedded profile); the
    /// cache is cleared if it ever grows past this.
    private static let limit = 16
    private static let byColorSpace = Mutex<[CGColorSpace: CIContext]>([:])

    /// A context that both works and outputs in `space`.
    static func context(workingIn space: CGColorSpace) -> CIContext {
        byColorSpace.withLock { cache in
            if let context = cache[space] { return context }
            if cache.count >= limit { cache.removeAll() }
            let context = CIContext(options: [.workingColorSpace: space, .outputColorSpace: space])
            cache[space] = context
            return context
        }
    }
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
        return CoreImageContexts.standard.createCGImage(oriented, from: oriented.extent, format: .RGBA8, colorSpace: space)
    }
}
