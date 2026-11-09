import BBModel
import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import BBAI

@Suite("ImageOps")
struct ImageOpsTests {
    private func size(_ w: Int, _ h: Int) -> PixelSize { PixelSize(width: w, height: h) }

    private func px(_ m: RegionMask, _ x: Int, _ y: Int) -> UInt8 { m.bytes[y * m.pixelSize.width + x] }

    private func encodeRGBA(_ bytes: [UInt8], _ w: Int, _ h: Int) -> Data {
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let img = CGImage(
            width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    /// Deterministic noisy opaque RGBA image as PNG.
    private func noisyPNG(_ w: Int, _ h: Int, seed: UInt64) -> Data {
        var state = seed
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        for i in 0..<(w * h) {
            for c in 0..<3 {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                bytes[i * 4 + c] = UInt8(truncatingIfNeeded: state >> 33)
            }
        }
        return encodeRGBA(bytes, w, h)
    }

    private func solidPNG(_ w: Int, _ h: Int, r: UInt8, g: UInt8, b: UInt8) -> Data {
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        for i in 0..<(w * h) { bytes[i * 4] = r; bytes[i * 4 + 1] = g; bytes[i * 4 + 2] = b }
        return encodeRGBA(bytes, w, h)
    }

    private func decodeRGBA(_ data: Data) -> (w: Int, h: Int, bytes: [UInt8]) {
        let src = CGImageSourceCreateWithData(data as CFData, nil)!
        let img = CGImageSourceCreateImageAtIndex(src, 0, nil)!
        let w = img.width, h = img.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        bytes.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return (w, h, bytes)
    }

    /// Square edit area [x0, x1) x [y0, y1) in a w x h mask.
    private func squareMask(_ w: Int, _ h: Int, _ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> RegionMask {
        var b = [UInt8](repeating: 0, count: w * h)
        for y in y0..<y1 { for x in x0..<x1 { b[y * w + x] = 255 } }
        return RegionMask(pixelSize: size(w, h), bytes: b)
    }

    @Test func brushHorizontalStroke() {
        let d = RegionMaskDrawing(pixelSize: size(100, 60), operations: [
            .brush(points: [CGPoint(x: 20, y: 30), CGPoint(x: 80, y: 30)], diameter: 10, erase: false),
        ])
        let m = ImageOps.rasterize(d)
        #expect(m.pixelSize == size(100, 60))
        #expect(px(m, 50, 30) == 255 && px(m, 50, 27) == 255 && px(m, 50, 33) == 255)
        #expect(px(m, 22, 30) == 255)
        #expect(px(m, 83, 30) == 255)  // round cap reaches past the end point
        for y in 0..<60 { for x in 0..<100 {
            let inside = x >= 14 && x <= 86 && y >= 24 && y <= 36
            if !inside { #expect(px(m, x, y) == 0) }
        } }
        // y = 0 is the top row.
        let top = ImageOps.rasterize(RegionMaskDrawing(pixelSize: size(40, 40), operations: [
            .brush(points: [CGPoint(x: 20, y: 2)], diameter: 6, erase: false),
        ]))
        #expect(px(top, 20, 2) == 255)
        #expect(px(top, 20, 37) == 0)
    }

    @Test func singlePointIsDot() {
        let m = ImageOps.rasterize(RegionMaskDrawing(pixelSize: size(50, 50), operations: [
            .brush(points: [CGPoint(x: 25, y: 25)], diameter: 12, erase: false),
        ]))
        #expect(px(m, 25, 25) == 255 && px(m, 25, 21) == 255)
        #expect(px(m, 25, 40) == 0 && px(m, 5, 5) == 0)
    }

    @Test func lassoSquare() {
        let pts = [CGPoint(x: 10, y: 10), CGPoint(x: 30, y: 10), CGPoint(x: 30, y: 30), CGPoint(x: 10, y: 30)]
        let m = ImageOps.rasterize(RegionMaskDrawing(pixelSize: size(40, 40), operations: [
            .lasso(points: pts, erase: false),
        ]))
        for y in 0..<40 { for x in 0..<40 {
            if (10..<30).contains(x) && (10..<30).contains(y) { #expect(px(m, x, y) == 255) }
            else { #expect(px(m, x, y) == 0) }
        } }
    }

    @Test func eraseAndInvertOrdering() {
        let big = [CGPoint(x: 0, y: 0), CGPoint(x: 40, y: 0), CGPoint(x: 40, y: 40), CGPoint(x: 0, y: 40)]
        let hole = [CGPoint(x: 10, y: 10), CGPoint(x: 20, y: 10), CGPoint(x: 20, y: 20), CGPoint(x: 10, y: 20)]
        let erased = ImageOps.rasterize(RegionMaskDrawing(pixelSize: size(40, 40), operations: [
            .lasso(points: big, erase: false), .lasso(points: hole, erase: true),
        ]))
        #expect(px(erased, 15, 15) == 0 && px(erased, 30, 30) == 255)
        let later = [CGPoint(x: 30, y: 30), CGPoint(x: 35, y: 30), CGPoint(x: 35, y: 35), CGPoint(x: 30, y: 35)]
        let inv = ImageOps.rasterize(RegionMaskDrawing(pixelSize: size(40, 40), operations: [
            .lasso(points: hole, erase: false), .invert, .lasso(points: later, erase: true),
        ]))
        #expect(px(inv, 15, 15) == 0)
        #expect(px(inv, 2, 2) == 255)
        #expect(px(inv, 32, 32) == 0)
        let inv2 = ImageOps.rasterize(RegionMaskDrawing(pixelSize: size(40, 40), operations: [
            .lasso(points: hole, erase: false), .invert, .invert,
        ]))
        #expect(px(inv2, 15, 15) == 255 && px(inv2, 2, 2) == 0)
        #expect(ImageOps.rasterize(RegionMaskDrawing(pixelSize: size(8, 8))).isEmpty)
    }

    @Test func grayscalePNGRoundTrip() throws {
        let d = RegionMaskDrawing(pixelSize: size(64, 48), operations: [
            .brush(points: [CGPoint(x: 5, y: 5), CGPoint(x: 50, y: 40)], diameter: 7.5, erase: false),
        ])
        let m = ImageOps.rasterize(d)
        let png = try ImageOps.grayscalePNG(m)
        #expect(try ImageOps.decodeMask(png) == m)
        let rgba = try ImageOps.decodeMask(solidPNG(4, 3, r: 255, g: 255, b: 255))
        #expect(rgba.pixelSize == size(4, 3) && rgba.bytes.allSatisfy { $0 == 255 })
        #expect(throws: ImageOpsError.undecodableImage) { try ImageOps.decodeMask(Data([1, 2, 3])) }
    }

    @Test func providerMaskPolarity() throws {
        let m = squareMask(20, 10, 5, 2, 10, 8)
        let r = decodeRGBA(try ImageOps.providerMaskPNG(m))
        #expect(r.w == 20 && r.h == 10)
        for y in 0..<10 { for x in 0..<20 {
            let i = (y * 20 + x) * 4
            let inside = (5..<10).contains(x) && (2..<8).contains(y)
            #expect(r.bytes[i + 3] == (inside ? 0 : 255))
            if !inside { #expect(r.bytes[i] == 0 && r.bytes[i + 1] == 0 && r.bytes[i + 2] == 0) }
        } }
    }

    @Test(arguments: [8.0, 16.0])
    func compositeExactOutsideBandAndEditedInside(feather: Double) throws {
        let w = 200, h = 160
        let orig = noisyPNG(w, h, seed: 1)
        let edit = noisyPNG(w, h, seed: 2)
        let mask = squareMask(w, h, 60, 50, 140, 110)
        let out = decodeRGBA(try ImageOps.composite(original: orig, edited: edit, mask: mask, featherPixels: feather))
        let o = decodeRGBA(orig), e = decodeRGBA(edit)
        #expect(out.w == w && out.h == h)
        var outsideChecked = 0, insideChecked = 0
        for y in 0..<h { for x in 0..<w {
            let dx = max(60 - x, 0, x - 139), dy = max(50 - y, 0, y - 109)
            let dist = Double(dx * dx + dy * dy).squareRoot()
            let i = (y * w + x) * 4
            let got = Array(out.bytes[i..<i + 4])
            if dist > feather {
                outsideChecked += 1
                #expect(got == Array(o.bytes[i..<i + 4]))
            }
            let f = Int(feather)
            if x >= 60 + f && x < 140 - f && y >= 50 + f && y < 110 - f {
                insideChecked += 1
                #expect(got == Array(e.bytes[i..<i + 4]))
            }
        } }
        #expect(outsideChecked > 1000 && insideChecked > 0)
    }

    @Test(arguments: [8.0, 16.0])
    func featherWidth(feather: Double) throws {
        let w = 200, h = 20
        let orig = solidPNG(w, h, r: 0, g: 0, b: 0)
        let edit = solidPNG(w, h, r: 200, g: 200, b: 200)
        let mask = squareMask(w, h, 100, 0, 200, 20)
        let out = decodeRGBA(try ImageOps.composite(original: orig, edited: edit, mask: mask, featherPixels: feather))
        let line = (0..<w).map { Int(out.bytes[(10 * w + $0) * 4]) }
        for x in 1..<w { #expect(line[x] >= line[x - 1]) }
        let start = line.firstIndex { $0 > 0 }!
        let end = line.firstIndex { $0 == 200 }!
        let width = Double(end - start)
        #expect(abs(width - feather) <= 2, "width \(width) vs \(feather)")
    }

    @Test func compositeResamplesEditedImage() throws {
        let w = 60, h = 40
        let orig = solidPNG(w, h, r: 10, g: 20, b: 30)
        let edit = solidPNG(120, 80, r: 200, g: 100, b: 50)
        let out = decodeRGBA(try ImageOps.composite(original: orig, edited: edit, mask: squareMask(w, h, 0, 0, 60, 40)))
        #expect(out.w == w && out.h == h)
        let i = (20 * w + 30) * 4
        #expect(Array(out.bytes[i..<i + 3]) == [200, 100, 50])
    }

    @Test func compositeRejectsMaskSizeMismatch() {
        let orig = solidPNG(10, 10, r: 0, g: 0, b: 0)
        #expect(throws: ImageOpsError.sizeMismatch(expected: size(10, 10), actual: size(5, 5))) {
            try ImageOps.composite(original: orig, edited: orig, mask: squareMask(5, 5, 0, 0, 2, 2))
        }
    }

    @Test func blackFillFraction() throws {
        let mask = squareMask(20, 20, 5, 5, 15, 15)
        let black = solidPNG(20, 20, r: 0, g: 0, b: 0)
        let colour = solidPNG(20, 20, r: 200, g: 40, b: 10)
        #expect(try ImageOps.blackFillFraction(of: black, in: mask) == 1)
        #expect(try ImageOps.blackFillFraction(of: colour, in: mask) == 0)
        let empty = RegionMask(pixelSize: size(20, 20), bytes: [UInt8](repeating: 0, count: 400))
        #expect(try ImageOps.blackFillFraction(of: black, in: empty) == 0)
    }
}
