import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Deterministic PRNG for reproducible noise.
struct SplitMix64 {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Builds a PNG from a per-pixel generator called in row-major order from the top-left. For `hasAlpha`
/// the pixels are written premultiplied (callers pass colour 0 where alpha is 0).
func makePNG(width: Int, height: Int, hasAlpha: Bool,
             pixel: (_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8, UInt8)) -> Data {
    precondition(width > 0 && height > 0)
    var buffer = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let p = pixel(x, y)
            let i = (y * width + x) * 4
            buffer[i] = p.0; buffer[i + 1] = p.1; buffer[i + 2] = p.2; buffer[i + 3] = p.3
        }
    }
    let info = hasAlpha ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast
    guard let provider = CGDataProvider(data: Data(buffer) as CFData),
          let image = CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: info.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
        preconditionFailure("could not build CGImage")
    }
    let out = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else {
        preconditionFailure("could not create PNG destination")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { preconditionFailure("could not encode PNG") }
    return out as Data
}

func decodeImage(_ data: Data) -> RGBAImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          CGImageSourceGetCount(source) > 0,
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
    let width = image.width, height = image.height
    guard width > 0, height > 0 else { return nil }
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
        guard let ctx = CGContext(
            data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    guard drawn else { return nil }
    // Memory row 0 is the top row of the drawn image. Un-premultiply so colours are meaningful under alpha.
    for i in stride(from: 0, to: pixels.count, by: 4) {
        let a = Int(pixels[i + 3])
        guard a > 0, a < 255 else { continue }
        for c in 0..<3 { pixels[i + c] = UInt8(min(255, (Int(pixels[i + c]) * 255 + a / 2) / a)) }
    }
    return RGBAImage(width: width, height: height, pixels: pixels)
}
