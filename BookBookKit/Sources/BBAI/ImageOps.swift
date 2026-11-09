import BBModel
import CoreGraphics
import Foundation
import ImageIO

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
        let w = drawing.pixelSize.width, h = drawing.pixelSize.height
        guard w > 0, h > 0 else { return RegionMask(pixelSize: drawing.pixelSize, bytes: []) }
        var bytes = [UInt8](repeating: 0, count: w * h)
        bytes.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(
                data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return }
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: 1, y: -1)
            ctx.setAllowsAntialiasing(true)
            ctx.setShouldAntialias(true)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            for op in drawing.operations {
                switch op {
                case let .brush(points, diameter, erase):
                    guard let first = points.first else { continue }
                    let gray: CGFloat = erase ? 0 : 1
                    let d = max(0, diameter)
                    if points.count == 1 {
                        ctx.setFillColor(gray: gray, alpha: 1)
                        ctx.fillEllipse(in: CGRect(x: first.x - d / 2, y: first.y - d / 2, width: d, height: d))
                    } else {
                        ctx.setStrokeColor(gray: gray, alpha: 1)
                        ctx.setLineWidth(d)
                        ctx.beginPath()
                        ctx.move(to: first)
                        for pt in points.dropFirst() { ctx.addLine(to: pt) }
                        ctx.strokePath()
                    }
                case let .lasso(points, erase):
                    guard let first = points.first else { continue }
                    ctx.setFillColor(gray: erase ? 0 : 1, alpha: 1)
                    ctx.beginPath()
                    ctx.move(to: first)
                    for pt in points.dropFirst() { ctx.addLine(to: pt) }
                    ctx.closePath()
                    ctx.fillPath(using: .winding)
                case .invert:
                    ctx.flush()
                    let p = buf.bindMemory(to: UInt8.self)
                    for i in 0..<p.count { p[i] = 255 &- p[i] }
                }
            }
            ctx.flush()
        }
        return RegionMask(pixelSize: drawing.pixelSize, bytes: bytes)
    }

    /// The user's mask as an 8-bit grayscale PNG (white = edit), stored in the book as `regionMask`.
    public static func grayscalePNG(_ mask: RegionMask) throws(ImageOpsError) -> Data {
        let w = mask.pixelSize.width, h = mask.pixelSize.height
        guard w > 0, h > 0, let provider = CGDataProvider(data: Data(mask.bytes) as CFData),
              let image = CGImage(
                width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw .encodingFailed }
        return try encodePNG(image)
    }

    /// Decodes a stored grayscale mask PNG back into a `RegionMask`.
    public static func decodeMask(_ png: Data) throws(ImageOpsError) -> RegionMask {
        let image = try decodeImage(png)
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h)
        let ok: Bool = bytes.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(
                data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { throw .undecodableImage }
        return RegionMask(pixelSize: PixelSize(width: w, height: h), bytes: bytes)
    }

    /// The OpenAI wire mask (SP-4 polarity): RGBA PNG at the mask's size, alpha 0 where the mask is
    /// edit (> 127), alpha 255 elsewhere. RGB is black.
    public static func providerMaskPNG(_ mask: RegionMask) throws(ImageOpsError) -> Data {
        let w = mask.pixelSize.width, h = mask.pixelSize.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) { rgba[i * 4 + 3] = mask.bytes[i] > 127 ? 0 : 255 }
        return try encodeRGBA(rgba, width: w, height: h)
    }

    /// Blends `edited` into `original` through `mask`, feathered by `featherPixels`: output pixels
    /// are exactly the original's wherever the feathered mask is 0 (further than the feather band
    /// from the edit area), and the edited image's wherever it's 255. `edited` is resampled to the
    /// original's size if the provider returned another size. Returns PNG data at the original's size.
    public static func composite(original: Data, edited: Data, mask: RegionMask,
                                 featherPixels: Double = defaultFeatherPixels) throws(ImageOpsError) -> Data {
        let orig = try decodeImage(original)
        let w = orig.width, h = orig.height
        guard mask.pixelSize == PixelSize(width: w, height: h) else {
            throw .sizeMismatch(expected: PixelSize(width: w, height: h), actual: mask.pixelSize)
        }
        let o = try rgba(of: orig, width: w, height: h)
        let e = try rgba(of: try decodeImage(edited), width: w, height: h)
        let m = feather(mask.bytes, width: w, height: h, featherPixels: featherPixels)
        var out = o
        for i in 0..<(w * h) {
            let a = Int(m[i])
            if a == 0 { continue }
            for c in 0..<3 {
                let ov = Int(o[i * 4 + c]), ev = Int(e[i * 4 + c])
                out[i * 4 + c] = UInt8((ov * (255 - a) + ev * a + 127) / 255)
            }
        }
        return try encodeRGBA(out, width: w, height: h)
    }

    /// The fraction (0...1) of edit-area pixels (mask > 127) in `image` that are near-black
    /// (max channel ≤ 16). Used to detect SP-4's "black hole" failure.
    public static func blackFillFraction(of image: Data, in mask: RegionMask) throws(ImageOpsError) -> Double {
        let w = mask.pixelSize.width, h = mask.pixelSize.height
        let px = try rgba(of: try decodeImage(image), width: w, height: h)
        var edit = 0, black = 0
        for i in 0..<(w * h) where mask.bytes[i] > 127 {
            edit += 1
            if max(px[i * 4], px[i * 4 + 1], px[i * 4 + 2]) <= 16 { black += 1 }
        }
        return edit == 0 ? 0 : Double(black) / Double(edit)
    }

    // MARK: Private helpers

    private static func decodeImage(_ data: Data) throws(ImageOpsError) -> CGImage {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw .undecodableImage }
        return img
    }

    private static func encodePNG(_ image: CGImage) throws(ImageOpsError) -> Data {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else {
            throw .encodingFailed
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw .encodingFailed }
        return out as Data
    }

    /// Premultiplied-last sRGB RGBA bytes, resampled (high quality) to `width` x `height`.
    private static func rgba(of image: CGImage, width: Int, height: Int) throws(ImageOpsError) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let ok: Bool = bytes.withUnsafeMutableBytes { buf in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(
                    data: buf.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { throw .undecodableImage }
        return bytes
    }

    private static func encodeRGBA(_ bytes: [UInt8], width: Int, height: Int) throws(ImageOpsError) -> Data {
        guard width > 0, height > 0, let provider = CGDataProvider(data: Data(bytes) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw .encodingFailed }
        return try encodePNG(image)
    }

    /// Separable box blur (window `2r + 1`, `r = floor(featherPixels / 2)`, edge-replicated) in
    /// integer arithmetic. A pixel is non-zero only if an edit pixel lies within `r` along both
    /// axes (so within `r * sqrt 2 <= featherPixels`), and it is exactly 255 deep inside the mask.
    private static func feather(_ src: [UInt8], width w: Int, height h: Int, featherPixels: Double) -> [UInt8] {
        let r = Int((max(0, featherPixels) / 2).rounded(.down))
        guard r > 0, w > 0, h > 0 else { return src }
        let n = 2 * r + 1
        var tmp = [Int32](repeating: 0, count: w * h)
        var out = src
        // Horizontal: sums (unnormalised, up to 255 * n).
        for y in 0..<h {
            let row = y * w
            for x in 0..<w {
                var sum: Int32 = 0
                for k in -r...r { sum += Int32(src[row + min(max(x + k, 0), w - 1)]) }
                tmp[row + x] = sum
            }
        }
        let div = Int32(n * n)
        for x in 0..<w {
            for y in 0..<h {
                var sum: Int32 = 0
                for k in -r...r { sum += tmp[min(max(y + k, 0), h - 1) * w + x] }
                out[y * w + x] = UInt8((sum + div / 2) / div)
            }
        }
        return out
    }
}
