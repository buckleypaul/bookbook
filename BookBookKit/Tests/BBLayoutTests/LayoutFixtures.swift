import AppKit
import BBLayout
import BBModel
import BBTestSupport
import CoreGraphics
import Foundation

/// Shared test fixtures: the bundled Atkinson Hyperlegible typography, an in-test template and
/// a page with a solid-colour placed image.
@MainActor
enum LayoutFixtures {
    static let typography = Typography(
        bodyFont: FontRef(postScriptName: TestFonts.Face.regular.rawValue),
        titleFont: FontRef(postScriptName: TestFonts.Face.bold.rawValue),
        bodySize: 15, color: .black, lineSpacing: 1.2, alignment: .leading)

    static func registerFonts() {
        precondition(TestFonts.registerAll(), "bundled test fonts failed to register")
    }

    static let imageBoxID = BoxID("00000000-0000-0000-0000-0000000000B1")
    static let textBoxID = BoxID("00000000-0000-0000-0000-0000000000B2")

    /// "Image on top, text below".
    static let template = Template(
        id: TemplateID("00000000-0000-0000-0000-0000000000A1"), name: "Image top, text below", kind: .single,
        boxes: [
            Box(id: imageBoxID, frame: NormalizedRect(x: 0.08, y: 0.06, width: 0.84, height: 0.52),
                cornerRadius: 8, content: .image),
            Box(id: textBoxID, frame: NormalizedRect(x: 0.08, y: 0.62, width: 0.84, height: 0.32),
                content: .text(TextBoxStyle(padding: 6, background: RGBA(red: 1, green: 0.97, blue: 0.88)))),
        ])

    /// Cover template (must have a different ID from the story template).
    static let coverTemplate = Template(name: "Cover", kind: .cover, boxes: [])

    static let sentences = "The fox wore a red scarf to the castle gate. Nobody had told her the castle was closed on Tuesdays."

    /// A one-story-page book on a small square trim, with a placed image of `imageRef`.
    static func content(imageRef: ImageRef, imagePixels: PixelSize, trim: PointSize = PointSize(width: 300, height: 300),
                        text: RichText = RichText(plain: sentences), pageCount: Int = 1) -> BookContent {
        var content = BookContent.makeNew(title: "Test", storyTemplate: template, coverTemplate: coverTemplate,
                                          storyPageCount: pageCount, now: Date(timeIntervalSince1970: 0))
        content.style.typography = typography
        content.style.pageSetup = PageSetup(trimSize: trim, orientation: .portrait, margins: EdgeInsetsPt(all: 18))
        for pageID in content.book.pageOrder {
            guard var page = content.pages[pageID], var slot = page.images[imageBoxID],
                  var session = content.sessions[slot.sessionID] else { continue }
            let version = Version(image: imageRef, pixelSize: imagePixels, source: .imported,
                                  createdAt: Date(timeIntervalSince1970: 0))
            session.versions.append(version)
            content.sessions[session.id] = session
            slot.placement = ImagePlacement(versionID: version.id, boxAspectWhenPlaced: 1)
            page.images[imageBoxID] = slot
            page.text[textBoxID] = text
            content.pages[pageID] = page
        }
        return content
    }

    /// A solid-colour sRGB bitmap.
    static func solidImage(width: Int, height: Int, red: CGFloat, green: CGFloat, blue: CGFloat) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    /// A bitmap context whose user space is `size` points, top-left origin, y down.
    static func flippedBitmap(size: CGSize, scale: CGFloat) -> CGContext {
        let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                            bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.translateBy(x: 0, y: size.height * scale)
        ctx.scaleBy(x: scale, y: -scale)
        return ctx
    }
}

/// An in-memory image source.
@MainActor
final class DictionaryImageSource: PageImageSource {
    var images: [ImageRef: CGImage]
    init(_ images: [ImageRef: CGImage] = [:]) { self.images = images }
    func image(for ref: ImageRef) -> CGImage? { images[ref] }
}
