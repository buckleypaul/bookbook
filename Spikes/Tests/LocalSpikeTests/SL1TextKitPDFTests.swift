// SL-1 (implementation-plan.md §4.3): does drawing NSTextLayoutFragments into a CGPDFContext keep
// text real and selectable, embed font subsets, and match the on-screen layout exactly?
//
// One TextKit 2 layout (NSTextContentStorage + NSTextLayoutManager + fixed-size NSTextContainer)
// is drawn with NSTextLayoutFragment.draw(at:in:) into (a) a bitmap CGContext and (b) a
// CGPDFContext writing to memory, both wrapped in an NSGraphicsContext (architecture.md §8.3).
// The PDF is then parsed with PDFKit (text, selection, character bounds) and CGPDFDocument
// (font resources), and rasterised to compare against the direct bitmap.
//
// Findings are printed as `SPIKE-RESULT SL-1 <key>: <value>` lines.

import AppKit
import CoreGraphics
import Foundation
import PDFKit
import Testing

@MainActor
@Suite("SL-1 TextKit 2 fragments into CGPDFContext", .serialized)
struct SL1TextKitPDFTests {
    // MARK: Fixture

    /// Page and text box geometry, in points. The box is inset on the page like a real text box.
    static let pageSize = CGSize(width: 432, height: 432)          // 6 x 6 in
    static let boxOrigin = CGPoint(x: 54, y: 60)                   // top-left of the box, page coords (flipped)
    static let boxSize = CGSize(width: 324, height: 300)

    static let paragraphs: [(text: String, font: NSFont)] = {
        let georgia = NSFont(name: "Georgia", size: 22) ?? .systemFont(ofSize: 22)
        let avenir = NSFont(name: "AvenirNext-DemiBold", size: 15) ?? .boldSystemFont(ofSize: 15)
        return [
            ("Once upon a time, a small brown bear lived at the edge of a very quiet wood.", georgia),
            ("Every morning he walked down to the river to count the stones and wave at the herons.",
             .systemFont(ofSize: 13)),
            ("One day the river was gone, and the bear was puzzled.", avenir),
            ("His fluffy friend, the owl, offered a waffle and some advice.", georgia),
        ]
    }()

    static func attributedText() -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (index, paragraph) in paragraphs.enumerated() {
            let style = NSMutableParagraphStyle()
            style.paragraphSpacing = 6
            style.alignment = index == 2 ? .center : .natural
            let text = paragraph.text + (index == paragraphs.count - 1 ? "" : "\n")
            result.append(NSAttributedString(string: text, attributes: [
                .font: paragraph.font,
                .foregroundColor: NSColor.black,
                .paragraphStyle: style,
            ]))
        }
        return result
    }

    /// The TextKit 2 stack. Kept alive together because NSTextContentStorage only weakly
    /// references its layout managers.
    final class Layout {
        let contentStorage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        let container: NSTextContainer
        var fragments: [NSTextLayoutFragment] = []

        init(text: NSAttributedString, size: CGSize) {
            container = NSTextContainer(size: size)
            container.lineFragmentPadding = 0
            layoutManager.textContainer = container
            contentStorage.addTextLayoutManager(layoutManager)
            contentStorage.textStorage = NSTextStorage(attributedString: text)
            layoutManager.ensureLayout(for: layoutManager.documentRange)
            layoutManager.enumerateTextLayoutFragments(
                from: layoutManager.documentRange.location, options: [.ensuresLayout]
            ) { fragment in
                self.fragments.append(fragment)
                return true
            }
        }

        func offset(of location: any NSTextLocation) -> Int {
            contentStorage.offset(from: contentStorage.documentRange.location, to: location)
        }
    }

    /// One glyph position from TextKit, in PDF page coordinates (origin bottom-left).
    struct ExpectedChar {
        let offset: Int            // UTF-16 offset in the source string
        let character: Character
        let x: CGFloat             // left edge of the character's advance box
        let baseline: CGFloat      // baseline y
        let font: NSFont
    }

    static func expectedCharacters(_ layout: Layout, text: NSAttributedString) -> [ExpectedChar] {
        let source = text.string as NSString
        var result: [ExpectedChar] = []
        for fragment in layout.fragments {
            let frame = fragment.layoutFragmentFrame
            let fragmentStart = layout.offset(of: fragment.rangeInElement.location)
            for line in fragment.textLineFragments {
                let lineBounds = line.typographicBounds
                // Baseline in flipped (top-left) box coordinates.
                let baselineFlipped = boxOrigin.y + frame.minY + lineBounds.minY + line.glyphOrigin.y
                let lineRange = line.characterRange
                for i in lineRange.location..<(lineRange.location + lineRange.length) {
                    let sourceOffset = fragmentStart + i
                    guard sourceOffset < source.length else { continue }
                    let unit = source.character(at: sourceOffset)
                    guard let scalar = Unicode.Scalar(unit), !CharacterSet.whitespacesAndNewlines.contains(scalar)
                    else { continue }
                    let loc = line.locationForCharacter(at: i)
                    let font = text.attribute(.font, at: sourceOffset, effectiveRange: nil) as? NSFont
                        ?? .systemFont(ofSize: 12)
                    result.append(ExpectedChar(
                        offset: sourceOffset,
                        character: Character(scalar),
                        x: boxOrigin.x + frame.minX + lineBounds.minX + loc.x,
                        baseline: pageSize.height - baselineFlipped,
                        font: font))
                }
            }
        }
        return result
    }

    // MARK: Drawing (the PageRenderer path from architecture.md §8.3)

    /// Draws every fragment into `ctx`, whose user space is unflipped PDF-style points
    /// (origin bottom-left). The flip happens here, once, like PageRenderer will do.
    static func drawText(_ layout: Layout, into ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: 0, y: pageSize.height)
        ctx.scaleBy(x: 1, y: -1)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        for fragment in layout.fragments {
            let origin = fragment.layoutFragmentFrame.origin
            fragment.draw(at: CGPoint(x: boxOrigin.x + origin.x, y: boxOrigin.y + origin.y), in: ctx)
        }
        NSGraphicsContext.current = previous
        ctx.restoreGState()
    }

    static func makePDF(_ layout: Layout) throws -> Data {
        let data = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        let ctx = try #require(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        ctx.beginPDFPage(nil)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(mediaBox)
        drawText(layout, into: ctx)
        ctx.endPDFPage()
        ctx.closePDF()
        return data as Data
    }

    static func makeBitmapContext(scale: CGFloat) throws -> CGContext {
        let ctx = try #require(CGContext(
            data: nil,
            width: Int(pageSize.width * scale), height: Int(pageSize.height * scale),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.scaleBy(x: scale, y: scale)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: pageSize))
        return ctx
    }

    static func result(_ key: String, _ value: Any) {
        print("SPIKE-RESULT SL-1 \(key): \(value)")
    }

    // MARK: Tests

    @Test("PDF keeps the text as real, searchable, selectable text")
    func textIsReal() throws {
        let text = Self.attributedText()
        let layout = Layout(text: text, size: Self.boxSize)
        let pdf = try Self.makePDF(layout)
        let document = try #require(PDFDocument(data: pdf))
        let page = try #require(document.page(at: 0))
        let extracted = try #require(document.string)

        let normalise: (String) -> String = { $0.precomposedStringWithCompatibilityMapping
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ") }
        let allPresent = Self.paragraphs.allSatisfy { normalise(extracted).contains(normalise($0.text)) }
        let exactPresent = Self.paragraphs.allSatisfy { extracted.contains($0.text) }
        Self.result("pdf-bytes", pdf.count)
        Self.result("layout-fragments", layout.fragments.count)
        Self.result("lines", layout.fragments.reduce(0) { $0 + $1.textLineFragments.count })
        Self.result("text-extractable (whitespace-normalised)", allPresent)
        Self.result("text-extractable (exact paragraphs)", exactPresent)
        Self.result("ligature-chars-in-pdf-string",
                    extracted.unicodeScalars.filter { (0xFB00...0xFB06).contains($0.value) }.count)
        Self.result("fluffy/waffle searchable", [
            !document.findString("fluffy", withOptions: []).isEmpty,
            !document.findString("waffle", withOptions: []).isEmpty,
        ])
        #expect(allPresent, "every paragraph should be extractable from the PDF")

        // Selection: find a phrase and check its bounds land inside the text box.
        let hits = document.findString("Once upon a time", withOptions: [])
        let hit = try #require(hits.first)
        let bounds = hit.bounds(for: page)
        let boxRectPDF = CGRect(x: Self.boxOrigin.x,
                                y: Self.pageSize.height - Self.boxOrigin.y - Self.boxSize.height,
                                width: Self.boxSize.width, height: Self.boxSize.height)
        Self.result("selection 'Once upon a time' bounds", bounds.integral)
        #expect(boxRectPDF.insetBy(dx: -1, dy: -1).contains(bounds))
        // A whole-page selection selects all text.
        let all = try #require(page.selection(for: NSRange(location: 0, length: page.numberOfCharacters)))
        Self.result("page-selection-chars", all.string?.count ?? 0)
        #expect((all.string?.count ?? 0) > 200)
    }

    @Test("PDF character positions match TextKit 2 layout within 0.5 pt")
    func positionsMatchLayout() throws {
        let text = Self.attributedText()
        let layout = Layout(text: text, size: Self.boxSize)
        let pdf = try Self.makePDF(layout)
        let document = try #require(PDFDocument(data: pdf))
        let page = try #require(document.page(at: 0))
        let pageString = try #require(page.string) as NSString
        let expected = Self.expectedCharacters(layout, text: text)

        // Walk the PDF page string in order, skipping whitespace, matching each non-whitespace
        // source character. A ligature in the PDF (e.g. U+FB02 "fl") consumes several source chars.
        var pdfIndex = 0
        var matched = 0
        var maxDX: CGFloat = 0
        var maxDBaseline: CGFloat = 0
        var worst = ""
        var mismatches = 0
        var inkQuirks = 0
        var e = 0
        while e < expected.count, pdfIndex < pageString.length {
            let unit = pageString.character(at: pdfIndex)
            if let s = Unicode.Scalar(unit), CharacterSet.whitespacesAndNewlines.contains(s) {
                pdfIndex += 1; continue
            }
            let pdfChar = String(utf16CodeUnits: [unit], count: 1)
            let decomposed = pdfChar.precomposedStringWithCompatibilityMapping
            let want = expected[e]
            guard decomposed.first == want.character else {
                mismatches += 1
                if mismatches > 5 { break }
                e += 1; continue
            }
            // Use the one-character selection's bounds: that is the advance box from descender to
            // ascender, so minX is the pen position and minY is baseline + descender. (Don't use
            // characterBounds(at:): it is ink-tight, and on macOS 27 its index runs one ahead of
            // page.string after each synthesized line break; see the quirk count below.)
            let selection = page.selection(for: NSRange(location: pdfIndex, length: 1))
            let bounds = selection?.bounds(for: page) ?? .null
            let ink = page.characterBounds(at: pdfIndex)
            if !bounds.insetBy(dx: -1, dy: -1).contains(CGPoint(x: ink.midX, y: ink.midY)) { inkQuirks += 1 }
            let baselineFromPDF = bounds.minY - want.font.descender
            let dx = abs(bounds.minX - want.x)
            let dy = abs(baselineFromPDF - want.baseline)
            if dx > maxDX || dy > maxDBaseline {
                worst = "'\(want.character)'@\(want.offset) textkit=(\(want.x), \(want.baseline)) " +
                        "pdf=(\(bounds.minX), \(baselineFromPDF))"
            }
            maxDX = max(maxDX, dx)
            maxDBaseline = max(maxDBaseline, dy)
            matched += 1
            e += decomposed.count
            pdfIndex += 1
        }
        Self.result("chars-compared", "\(matched) of \(expected.count)")
        Self.result("sequence-mismatches", mismatches)
        Self.result("max-x-delta-pt", String(format: "%.3f", maxDX))
        Self.result("max-baseline-delta-pt", String(format: "%.3f", maxDBaseline))
        Self.result("worst-char", worst)
        Self.result("characterBounds(at:) not on the selected char (PDFKit quirk)", "\(inkQuirks) of \(matched)")
        #expect(matched == expected.count, "every laid-out character should be found in the PDF text")
        #expect(maxDX <= 0.5)
        #expect(maxDBaseline <= 0.5)
    }

    @Test("PDF raster matches the direct bitmap render")
    func rasterMatchesBitmap() throws {
        let text = Self.attributedText()
        let layout = Layout(text: text, size: Self.boxSize)
        let scale: CGFloat = 2

        let direct = try Self.makeBitmapContext(scale: scale)
        Self.drawText(layout, into: direct)

        let pdf = try Self.makePDF(layout)
        let provider = try #require(CGDataProvider(data: pdf as CFData))
        let pdfDoc = try #require(CGPDFDocument(provider))
        let pdfPage = try #require(pdfDoc.page(at: 1))
        let viaPDF = try Self.makeBitmapContext(scale: scale)
        viaPDF.drawPDFPage(pdfPage)

        let a = try #require(direct.data).assumingMemoryBound(to: UInt8.self)
        let b = try #require(viaPDF.data).assumingMemoryBound(to: UInt8.self)
        var maxDiff = 0, sumDiff = 0, over32 = 0, ink = 0
        var inkBoundsA = CGRect.null, inkBoundsB = CGRect.null
        for row in 0..<direct.height {
            for col in 0..<direct.width {
                let i = row * direct.bytesPerRow + col * 4
                let va = Int(a[i]), vb = Int(b[i])     // red channel; text is black on white
                let d = abs(va - vb)
                maxDiff = max(maxDiff, d); sumDiff += d
                if d > 32 { over32 += 1 }
                let pixel = CGRect(x: col, y: row, width: 1, height: 1)
                if va < 128 { ink += 1; inkBoundsA = inkBoundsA.union(pixel) }
                if vb < 128 { inkBoundsB = inkBoundsB.union(pixel) }
            }
        }
        let pixels = direct.width * direct.height
        Self.result("raster-scale", scale)
        Self.result("ink-pixels", ink)
        Self.result("ink-bounds direct vs via-PDF (px)", "\(inkBoundsA) vs \(inkBoundsB)")
        Self.result("max-channel-diff", maxDiff)
        Self.result("mean-channel-diff", String(format: "%.4f", Double(sumDiff) / Double(pixels)))
        Self.result("pixels-differing>32", "\(over32) (\(String(format: "%.4f", Double(over32) * 100 / Double(pixels)))%)")
        #expect(ink > 1000, "the direct render should contain text")
        #expect(inkBoundsA == inkBoundsB, "ink bounding boxes should be identical")
        #expect(Double(over32) / Double(ink) < 0.02, "fewer than 2% of ink pixels may differ noticeably")
    }

    @Test("PDF embeds the fonts as subsets")
    func fontsEmbeddedAsSubsets() throws {
        let text = Self.attributedText()
        let layout = Layout(text: text, size: Self.boxSize)
        let pdf = try Self.makePDF(layout)
        let provider = try #require(CGDataProvider(data: pdf as CFData))
        let doc = try #require(CGPDFDocument(provider))
        let page = try #require(doc.page(at: 1))
        let pageDict = try #require(page.dictionary)

        let fonts = PDFFontWalker.fonts(inPage: pageDict)
        for font in fonts {
            Self.result("font", font.summary)
        }
        Self.result("font-count", fonts.count)
        Self.result("used-fonts (TextKit)", Self.paragraphs.map(\.font.fontName))
        #expect(fonts.count >= 3, "three distinct faces are used")
        #expect(fonts.allSatisfy { $0.isEmbedded }, "every font should have an embedded font file")
        #expect(fonts.allSatisfy { $0.isSubset }, "every font should be a subset (ABCDEF+Name)")
    }
}

/// Walks a CGPDF page's resources (including Form XObjects) and reports each /Font.
enum PDFFontWalker {
    struct FontInfo {
        let resourceName: String
        let subtype: String
        let baseFont: String
        let descendantSubtype: String?
        let fontFileKeys: [String]

        var isSubset: Bool {
            let parts = baseFont.split(separator: "+", maxSplits: 1)
            return parts.count == 2 && parts[0].count == 6 && parts[0].allSatisfy { $0.isUppercase }
        }
        var isEmbedded: Bool { !fontFileKeys.isEmpty }
        var summary: String {
            "\(resourceName) \(subtype)\(descendantSubtype.map { "/\($0)" } ?? "") \(baseFont) " +
            "file=\(fontFileKeys.isEmpty ? "none" : fontFileKeys.joined(separator: ","))"
        }
    }

    static func fonts(inPage page: CGPDFDictionaryRef) -> [FontInfo] {
        var result: [FontInfo] = []
        var resources: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(page, "Resources", &resources), let resources {
            collect(resources: resources, into: &result, depth: 0)
        }
        return result
    }

    private static func collect(resources: CGPDFDictionaryRef, into result: inout [FontInfo], depth: Int) {
        var fontDict: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(resources, "Font", &fontDict), let fontDict {
            var found: [FontInfo] = []
            CGPDFDictionaryApplyBlock(fontDict, { key, object, _ in
                var dict: CGPDFDictionaryRef?
                if CGPDFObjectGetValue(object, .dictionary, &dict), let dict {
                    found.append(info(name: String(cString: key), font: dict))
                }
                return true
            }, nil)
            result.append(contentsOf: found)
        }
        guard depth < 4 else { return }
        var xobjects: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects), let xobjects {
            var nested: [CGPDFDictionaryRef] = []
            CGPDFDictionaryApplyBlock(xobjects, { _, object, _ in
                var stream: CGPDFStreamRef?
                if CGPDFObjectGetValue(object, .stream, &stream), let stream,
                   let dict = CGPDFStreamGetDictionary(stream) {
                    var res: CGPDFDictionaryRef?
                    if CGPDFDictionaryGetDictionary(dict, "Resources", &res), let res { nested.append(res) }
                }
                return true
            }, nil)
            for res in nested { collect(resources: res, into: &result, depth: depth + 1) }
        }
    }

    private static func name(_ dict: CGPDFDictionaryRef, _ key: String) -> String? {
        var value: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(dict, key, &value), let value else { return nil }
        return String(cString: value)
    }

    private static func fontFiles(_ dict: CGPDFDictionaryRef) -> [String] {
        var descriptor: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dict, "FontDescriptor", &descriptor), let descriptor else { return [] }
        return ["FontFile", "FontFile2", "FontFile3"].filter { key in
            var stream: CGPDFStreamRef?
            return CGPDFDictionaryGetStream(descriptor, key, &stream)
        }.map { key in
            var stream: CGPDFStreamRef?
            if key == "FontFile3", CGPDFDictionaryGetStream(descriptor, key, &stream), let stream,
               let streamDict = CGPDFStreamGetDictionary(stream), let sub = name(streamDict, "Subtype") {
                return "\(key)(\(sub))"
            }
            return key
        }
    }

    private static func info(name resourceName: String, font: CGPDFDictionaryRef) -> FontInfo {
        let subtype = name(font, "Subtype") ?? "?"
        let baseFont = name(font, "BaseFont") ?? "?"
        var files = fontFiles(font)
        var descendantSubtype: String?
        var descendants: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(font, "DescendantFonts", &descendants), let descendants {
            var child: CGPDFDictionaryRef?
            if CGPDFArrayGetDictionary(descendants, 0, &child), let child {
                descendantSubtype = name(child, "Subtype")
                files += fontFiles(child)
            }
        }
        return FontInfo(resourceName: resourceName, subtype: subtype, baseFont: baseFont,
                        descendantSubtype: descendantSubtype, fontFileKeys: files)
    }
}
