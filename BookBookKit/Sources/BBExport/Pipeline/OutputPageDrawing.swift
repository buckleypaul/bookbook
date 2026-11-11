import BBLayout
import BBModel
import CoreGraphics
import Foundation

/// One output page: a whole page (a single page, the cover, or a spread at double width), one
/// half of a spread, or a booklet blank (`page == nil`).
struct OutputSlot {
    var page: Page?
    /// 0 or 1 for one half of a spread; nil for the whole page.
    var half: Int?

    static let blank = OutputSlot(page: nil, half: nil)
}

/// Shared page drawing for every export path (A §9.1): `BookExporter`'s PDFs and bitmaps.
@MainActor
enum OutputPageDrawing {
    /// The trim size of `slot`'s output page: double width for a whole spread.
    static func trimSize(of slot: OutputSlot, in content: BookContent) -> CGSize {
        let kind = slot.half == nil ? slot.page.flatMap { content.template(for: $0)?.kind } : nil
        return PageGeometry(setup: content.style.pageSetup, kind: kind).trimSize
    }

    /// Draws `slot` into `ctx`, whose user space is the output page's trim (origin top-left,
    /// y down). Clips to the trim grown by `bleed` (0 clips to the trim). A spread half is the
    /// double-width spread shifted and clipped to that half, with only that half's page number;
    /// with bleed, the half's bleed on the fold side shows the facing half, as a trimmed sheet would.
    static func draw(_ slot: OutputSlot, content: BookContent, renderer: PageRenderer,
                     marks: [PageNumberMark], target: RenderOptions.Target, bleed: CGFloat, ctx: CGContext) {
        guard let page = slot.page else { return drawBlank(size: trimSize(of: slot, in: content), ctx: ctx) }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        guard content.isSpread(page) else {
            let trim = PageGeometry(setup: content.style.pageSetup).trimRect
            ctx.clip(to: trim.insetBy(dx: -bleed, dy: -bleed))
            renderer.draw(page: page, in: content, into: ctx,
                          options: RenderOptions(target: target, pageNumbers: marks))
            return
        }
        let single = PageGeometry(setup: content.style.pageSetup).trimSize
        guard let half = slot.half else {
            let trim = PageGeometry(setup: content.style.pageSetup, kind: .spread).trimRect
            ctx.clip(to: trim.insetBy(dx: -bleed, dy: -bleed))
            renderer.draw(page: page, in: content, into: ctx,
                          options: RenderOptions(target: target, pageNumbers: marks))
            return
        }
        let halfRect = CGRect(x: CGFloat(half) * single.width, y: 0, width: single.width, height: single.height)
        let visible = halfRect.insetBy(dx: -bleed, dy: -bleed)
        ctx.translateBy(x: -halfRect.minX, y: 0)
        ctx.clip(to: visible)
        let options = RenderOptions(target: target, pageNumbers: marks.filter { $0.half == half })
        renderer.draw(page: page, in: content, into: ctx, options: options, visibleRect: visible)
    }

    /// A booklet blank: plain white.
    static func drawBlank(size: CGSize, ctx: CGContext) {
        ctx.saveGState()
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
        ctx.restoreGState()
    }

    /// Flips a PDF page's y-up user space to y-down over a media box of `height`.
    static func flipToTopLeft(_ ctx: CGContext, height: CGFloat) {
        ctx.translateBy(x: 0, y: height)
        ctx.scaleBy(x: 1, y: -1)
    }

    /// A `CGRect` as the `CFData` value `beginPDFPage`'s page-info keys expect.
    static func boxValue(_ rect: CGRect) -> CFData {
        var rect = rect
        return withUnsafeBytes(of: &rect) { Data($0) } as CFData
    }

    /// The document info for a book.
    static func documentInfo(_ content: BookContent) -> CFDictionary {
        var info: [CFString: Any] = [kCGPDFContextCreator: "BookBook"]
        if !content.book.title.isEmpty { info[kCGPDFContextTitle] = content.book.title }
        if !content.book.author.isEmpty { info[kCGPDFContextAuthor] = content.book.author }
        return info as CFDictionary
    }
}
