import BBLayout
import BBModel
import CoreGraphics
import SwiftUI

/// Renders page thumbnails for the Pages overview with `PageRenderer` (thumbnail target), and
/// keeps them in memory keyed by everything that affects the drawing, so an unchanged page
/// isn't redrawn when another one changes. One per book window.
@MainActor
final class PageThumbnailRenderer {
    private struct Key: Hashable {
        var page: Page
        var template: Template?
        var style: StyleGuide
        var title: String
        var author: String
        var marks: [PageNumberMark]
        var pixelHeight: Int
    }

    private let images: any PageImageSource
    private var cache: [Key: CGImage] = [:]
    private var order: [Key] = []
    private let capacity: Int

    init(images: any PageImageSource, capacity: Int = 200) {
        self.images = images
        self.capacity = capacity
    }

    /// The trim size a page is drawn at: double width for a spread (its boxes are normalized
    /// over both pages, A §4.1).
    static func drawSize(for page: Page, in content: BookContent) -> CGSize {
        PageGeometry(setup: content.style.pageSetup, kind: content.template(for: page)?.kind).trimSize
    }

    /// The whole page (both halves for a spread), `pixelHeight` tall.
    func image(for pageID: PageID, in content: BookContent, marks: [PageNumberMark], pixelHeight: Int) -> CGImage? {
        guard let page = content.pages[pageID], pixelHeight > 0 else { return nil }
        let template = content.template(for: page)
        let key = Key(page: page, template: template, style: content.style, title: content.book.title,
                      author: content.book.author, marks: marks, pixelHeight: pixelHeight)
        if let image = cache[key] { return image }

        let size = Self.drawSize(for: page, in: content)
        guard size.width > 0, size.height > 0 else { return nil }
        let height = pixelHeight
        let width = max(1, Int((Double(height) * size.width / size.height).rounded()))
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // PageRenderer wants trim points, origin top-left, y down.
        ctx.translateBy(x: 0, y: Double(height))
        ctx.scaleBy(x: Double(width) / size.width, y: -Double(height) / size.height)
        var drawContent = content
        drawContent.style.pageSetup.trimSize = PointSize(width: size.width, height: size.height)
        var options = RenderOptions(target: .thumbnail)
        options.pageNumbers = marks
        PageRenderer(images: images).draw(page: page, in: drawContent, into: ctx, options: options)
        guard let image = ctx.makeImage() else { return nil }

        cache[key] = image
        order.append(key)
        if order.count > capacity { cache[order.removeFirst()] = nil }
        return image
    }
}

/// One page (or half a split spread) in the overview: the thumbnail, a status badge, a label,
/// and selection / drop highlighting.
struct PageThumbnailView: View {
    let image: CGImage?
    let part: OverviewPart
    /// Size of one page side, in points.
    let sideSize: CGSize
    /// 1 for a single page or half, 2 for a spread filling both sides.
    let sides: Int
    let status: PageStatus?
    let label: String?
    let isSelected: Bool
    let isDropTarget: Bool

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                pageImage
                    .frame(width: sideSize.width * CGFloat(sides), height: sideSize.height)
                    .clipped()
                    .background(.white)
                    .overlay(alignment: .center) {
                        if sides == 2 {
                            // The centre fold.
                            Rectangle().fill(.black.opacity(0.15)).frame(width: 1)
                        }
                    }
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                if let status { StatusBadge(status: status).padding(4) }
                if part != .single {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .padding(4)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .help("This spread is split across two sheets")
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(isDropTarget ? Color.accentColor : (isSelected ? Color.accentColor : .clear),
                                  lineWidth: isDropTarget ? 3 : 2)
                    .padding(-3)
            }
            Text(label ?? " ")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var pageImage: some View {
        if let image {
            let full = Image(decorative: image, scale: 1).resizable()
            switch part {
            case .single:
                full
            case .splitLeftHalf:
                full.frame(width: sideSize.width * 2, height: sideSize.height)
                    .frame(width: sideSize.width, alignment: .leading)
            case .splitRightHalf:
                full.frame(width: sideSize.width * 2, height: sideSize.height)
                    .frame(width: sideSize.width, alignment: .trailing)
            }
        } else {
            Color.white
        }
    }
}

/// Empty / In progress / Done (A §4.4).
struct StatusBadge: View {
    let status: PageStatus

    var body: some View {
        let (symbol, color, text): (String, Color, String) = switch status {
        case .empty: ("circle.dashed", .secondary, "Empty")
        case .inProgress: ("circle.lefthalf.filled", .orange, "In progress")
        case .done: ("checkmark.circle.fill", .green, "Done")
        }
        Image(systemName: symbol)
            .foregroundStyle(color)
            .padding(2)
            .background(.regularMaterial, in: Circle())
            .help(text)
            .accessibilityLabel(text)
    }
}
