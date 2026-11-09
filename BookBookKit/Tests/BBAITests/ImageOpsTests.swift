import Accelerate
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

    // MARK: Composite keeps the base's colour space, depth and alpha

    enum BaseKind: String, CaseIterable, Sendable { case displayP3JPEG, sixteenBitPNG, alphaPNG }

    /// Deterministic noisy image: `bpc` 8 or 16, RGBA non-premultiplied (alpha noisy too when `alpha`).
    private func noisyImage(_ w: Int, _ h: Int, bpc: Int, space: CGColorSpace, alpha: Bool, seed: UInt64) -> CGImage {
        var state = seed
        func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state >> 33 }
        let count = w * h * 4
        let data: Data
        if bpc == 16 {
            var v = [UInt16](repeating: .max, count: count)
            for i in 0..<count where alpha || i % 4 != 3 { v[i] = UInt16(truncatingIfNeeded: next()) }
            data = v.withUnsafeBytes { Data($0) }
        } else {
            var v = [UInt8](repeating: .max, count: count)
            for i in 0..<count where alpha || i % 4 != 3 { v[i] = UInt8(truncatingIfNeeded: next()) }
            data = Data(v)
        }
        var info = CGBitmapInfo(rawValue: (alpha ? CGImageAlphaInfo.last : .noneSkipLast).rawValue)
        if bpc == 16 { info.insert(.byteOrder16Little) }
        return CGImage(width: w, height: h, bitsPerComponent: bpc, bitsPerPixel: bpc * 4, bytesPerRow: w * bpc / 2,
                       space: space, bitmapInfo: info, provider: CGDataProvider(data: data as CFData)!,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    private func encode(_ image: CGImage, type: String) -> Data {
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, type as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    /// Decoded pixels as 16-bit non-premultiplied RGBA in `space` (lossless for 8- or 16-bit sources in that space).
    private func pixels16(_ data: Data, space: CGColorSpace) throws -> (image: CGImage, values: [UInt16]) {
        let src = CGImageSourceCreateWithData(data as CFData, nil)!
        let img = CGImageSourceCreateImageAtIndex(src, 0, nil)!
        var info = CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)
        info.insert(.byteOrder16Little)
        let format = vImage_CGImageFormat(bitsPerComponent: 16, bitsPerPixel: 64, colorSpace: space,
                                          bitmapInfo: info, renderingIntent: .defaultIntent)!
        let buf = try vImage_Buffer(cgImage: img, format: format)
        defer { buf.free() }
        var values = [UInt16]()
        values.reserveCapacity(img.width * img.height * 4)
        for y in 0..<img.height {
            let row = (buf.data + y * buf.rowBytes).assumingMemoryBound(to: UInt16.self)
            values.append(contentsOf: UnsafeBufferPointer(start: row, count: img.width * 4))
        }
        return (img, values)
    }

    @Test(arguments: BaseKind.allCases)
    func compositePreservesBaseOutsideBand(kind: BaseKind) throws {
        let w = 120, h = 90
        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let space: CGColorSpace
        let orig: Data
        switch kind {
        case .displayP3JPEG:
            space = p3
            orig = encode(noisyImage(w, h, bpc: 8, space: p3, alpha: false, seed: 3), type: "public.jpeg")
        case .sixteenBitPNG:
            space = srgb
            orig = encode(noisyImage(w, h, bpc: 16, space: srgb, alpha: false, seed: 4), type: "public.png")
        case .alphaPNG:
            space = srgb
            orig = encode(noisyImage(w, h, bpc: 8, space: srgb, alpha: true, seed: 5), type: "public.png")
        }
        let edit = noisyPNG(w, h, seed: 9)
        let out = try ImageOps.composite(original: orig, edited: edit, mask: squareMask(w, h, 40, 30, 80, 60))
        let o = try pixels16(orig, space: space), c = try pixels16(out, space: space)
        #expect(c.image.width == w && c.image.height == h)
        if kind == .sixteenBitPNG { #expect(c.image.bitsPerComponent == 16) }
        if kind == .alphaPNG { #expect(![.none, .noneSkipLast, .noneSkipFirst].contains(c.image.alphaInfo)) }
        var checked = 0, mismatched = 0, changedInside = 0
        for y in 0..<h { for x in 0..<w {
            let dx = max(40 - x, 0, x - 79), dy = max(30 - y, 0, y - 59)
            let i = (y * w + x) * 4
            if Double(dx * dx + dy * dy).squareRoot() > ImageOps.defaultFeatherPixels {
                checked += 1
                if c.values[i..<i + 4] != o.values[i..<i + 4] { mismatched += 1 }
            } else if dx == 0 && dy == 0, c.values[i..<i + 4] != o.values[i..<i + 4] {
                changedInside += 1
            }
        } }
        #expect(mismatched == 0, "\(mismatched) of \(checked) pixels outside the band changed")
        #expect(checked > 5000 && changedInside > 0)
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

    /// The per-tap box blur `feather` used before its running-sum rewrite, kept as the reference.
    private func referenceFeather(_ src: [UInt8], width w: Int, height h: Int, featherPixels: Double) -> [UInt8] {
        let r = Int((max(0, featherPixels) / 2).rounded(.down))
        guard r > 0, w > 0, h > 0 else { return src }
        let n = 2 * r + 1
        var tmp = [Int32](repeating: 0, count: w * h)
        var out = src
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

    /// The running-sum feather is bit-identical to the per-tap one, including windows wider than
    /// the image (edge replication on both sides).
    @Test(arguments: [(97, 61, 8.0), (13, 9, 8.0), (3, 2, 9.0), (1, 40, 4.0), (40, 1, 6.0), (50, 50, 1.0)])
    func featherMatchesPerTapBoxBlur(width: Int, height: Int, feather: Double) {
        var rng = SplitMix64(seed: UInt64(width * 1000 + height))
        // Random noise plus solid blocks, so both busy and flat areas are covered.
        let src = (0..<(width * height)).map { i -> UInt8 in
            let x = i % width, y = i / width
            if (x / 7 + y / 5) % 3 == 0 { return 255 }
            return UInt8(truncatingIfNeeded: rng.next())
        }
        let new = ImageOps.feather(src, width: width, height: height, featherPixels: feather)
        let old = referenceFeather(src, width: width, height: height, featherPixels: feather)
        #expect(new == old)
    }
}

/// A seeded generator, so the random mask is the same on every run.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
