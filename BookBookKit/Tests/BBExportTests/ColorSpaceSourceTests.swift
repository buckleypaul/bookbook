import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import BBExport

/// Non-RGB sources (gray PNG, CMYK JPEG) must not abort export.
enum ColorSpaceFixtures {
    static func gray(width: Int, height: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setFillColor(gray: 0.7, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(gray: 0.2, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 2))
        return ctx.makeImage()!
    }

    static func cmyk(width: Int, height: Int) -> CGImage {
        let space = CGColorSpaceCreateDeviceCMYK()
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setFillColor(CGColor(colorSpace: space, components: [0.1, 0.6, 0.8, 0.1, 1])!)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(colorSpace: space, components: [0.8, 0.2, 0.1, 0.1, 1])!)
        ctx.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 2))
        return ctx.makeImage()!
    }

    static func displayP3(width: Int, height: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.displayP3)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(red: 0.9, green: 0.3, blue: 0.2, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    static func write(_ image: CGImage, type: UTType, to url: URL, orientation: Int? = nil) {
        let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        let props: [CFString: Any] = orientation.map { [kCGImagePropertyOrientation: $0] } ?? [:]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        precondition(CGImageDestinationFinalize(dest))
    }
}

@Suite("Non-RGB sources")
struct ColorSpaceSourceTests {
    @Test func upscalerHandlesGray() async throws {
        let out = try await CoreImageUpscaler().upscale(ColorSpaceFixtures.gray(width: 40, height: 30),
                                                        to: CGSize(width: 100, height: 75))
        #expect(out.width == 100 && out.height == 75)
    }

    @Test func upscalerHandlesCMYK() async throws {
        let out = try await CoreImageUpscaler().upscale(ColorSpaceFixtures.cmyk(width: 40, height: 30),
                                                        to: CGSize(width: 100, height: 75))
        #expect(out.width == 100 && out.height == 75)
    }

    @Test func upscalerDownsamplesGray() async throws {
        let out = try await CoreImageUpscaler().upscale(ColorSpaceFixtures.gray(width: 200, height: 100),
                                                        to: CGSize(width: 50, height: 25))
        #expect(out.width == 50 && out.height == 25)
    }

    @Test func upscalerKeepsDisplayP3() async throws {
        let out = try await CoreImageUpscaler().upscale(ColorSpaceFixtures.displayP3(width: 20, height: 20),
                                                        to: CGSize(width: 50, height: 50))
        #expect(out.colorSpace?.name as String? == CGColorSpace.displayP3 as String)
    }

    @Test func preparerHandlesGrayPNG() async throws {
        let dir = ImageTestSupport.tempDir()
        let src = dir.appendingPathComponent("gray.png")
        ColorSpaceFixtures.write(ColorSpaceFixtures.gray(width: 64, height: 48), type: .png, to: src)
        let preparer = ExportImagePreparer(cacheDirectory: dir.appendingPathComponent("cache"))
        let image = try await preparer.prepare(ImageTestSupport.request(
            crop: CGRect(x: 0, y: 0, width: 64, height: 48), required: CGSize(width: 128, height: 96), url: src, sha: "gray"))
        #expect(image.width == 128 && image.height == 96)
    }

    @Test func preparerHandlesCMYKJPEG() async throws {
        let dir = ImageTestSupport.tempDir()
        let src = dir.appendingPathComponent("cmyk.jpg")
        ColorSpaceFixtures.write(ColorSpaceFixtures.cmyk(width: 64, height: 48), type: .jpeg, to: src)
        let preparer = ExportImagePreparer(cacheDirectory: dir.appendingPathComponent("cache"))
        let image = try await preparer.prepare(ImageTestSupport.request(
            crop: CGRect(x: 0, y: 0, width: 64, height: 48), required: CGSize(width: 128, height: 96), url: src, sha: "cmyk"))
        #expect(image.width == 128 && image.height == 96)
    }

    @Test func orientedDecodeHandlesGrayAndCMYK() {
        let dir = ImageTestSupport.tempDir()
        let cases: [(String, CGImage)] = [("g.jpg", ColorSpaceFixtures.gray(width: 30, height: 20)),
                                          ("c.jpg", ColorSpaceFixtures.cmyk(width: 30, height: 20))]
        for (name, img) in cases {
            let url = dir.appendingPathComponent(name)
            ColorSpaceFixtures.write(img, type: .jpeg, to: url, orientation: 6)
            let decoded = ImageFiles.decodeOriented(url: url)
            #expect(decoded != nil, "\(name)")
            #expect(decoded?.width == 20 && decoded?.height == 30, "\(name)")
        }
    }
}
