import BBLayout
import BBModel
import CoreGraphics
import SwiftUI

/// Renders page thumbnails for the Pages overview with `PageRenderer` (thumbnail target), and
/// keeps them in memory keyed by everything that affects the drawing, so an unchanged page
/// isn't redrawn when another one changes. One per book window.
@MainActor
final class PageThumbnailRenderer {
    /// What `PageRenderer` reads to draw a page at the thumbnail target: the template, the
    /// page's text and placed images, the style's typography, page setup and page-number style,
    /// and the cover's bound title and author. The rest of the style (description, guidance,
    /// references) and of the page (status, asset list, flag baselines) never shows.
    private struct Key: Hashable {
        var template: Template?
        var text: [BoxID: RichText]
        var images: [BoxID: PlacedImage]
        var typography: Typography
        var pageSetup: PageSetup
        var pageNumbers: PageNumberStyle
        var title: String
        var author: String
        var marks: [PageNumberMark]
        var pixelHeight: Int

        init(page: Page, in content: BookContent, marks: [PageNumberMark], pixelHeight: Int) {
            template = content.template(for: page)
            text = page.text
            var images: [BoxID: PlacedImage] = [:]
            for (box, slot) in page.images {
                guard let placement = slot.placement else { continue }
                images[box] = PlacedImage(image: content.placedVersion(page: page.id, box: box)?.image,
                                          placement: placement)
            }
            self.images = images
            typography = content.style.typography
            pageSetup = content.style.pageSetup
            pageNumbers = content.style.pageNumbers
            title = content.book.title
            author = content.book.author
            self.marks = marks
            self.pixelHeight = pixelHeight
        }
    }

    /// A placed picture: the image drawn and how it sits in its box.
    private struct PlacedImage: Hashable {
        var image: ImageRef?
        var placement: ImagePlacement
    }

    private let images: any PageImageSource
    /// Reuses text layouts when a page redraws with the same text (another size, a new picture).
    private let layouts = TextBoxLayoutCache()
    private var cache: [Key: CGImage] = [:]
    private var order: [Key] = []
    private let capacity: Int
    /// `BookDocument.fontsRevision` the cached layouts and thumbnails were made under.
    private var fontsRevision: Int?

    init(images: any PageImageSource, capacity: Int = 200) {
        self.images = images
        self.capacity = capacity
    }

    /// The whole page (both halves for a spread), `pixelHeight` tall. `fontsRevision` is
    /// `BookDocument.fontsRevision`, as the canvas takes it.
    func image(for pageID: PageID, in content: BookContent, marks: [PageNumberMark], pixelHeight: Int,
               fontsRevision: Int = 0) -> CGImage? {
        // Fonts were registered since the layouts and thumbnails were made: they may have used a
        // fallback font.
        if fontsRevision != self.fontsRevision {
            self.fontsRevision = fontsRevision
            layouts.removeAll()
            cache.removeAll()
            order.removeAll()
        }
        guard let page = content.pages[pageID], pixelHeight > 0 else { return nil }
        let key = Key(page: page, in: content, marks: marks, pixelHeight: pixelHeight)
        if let image = cache[key] { return image }

        // Double width for a spread (its boxes are normalized over both pages, A §4.1).
        let size = PageGeometry.drawGeometry(for: page, in: content).trimSize
        guard size.width > 0, size.height > 0 else { return nil }
        let height = pixelHeight
        let width = max(1, Int((Double(height) * size.width / size.height).rounded()))
        var options = RenderOptions(target: .thumbnail)
        options.pageNumbers = marks
        guard let image = ThumbnailRendering.render(page: page, in: content, trim: size, pixelWidth: width,
                                                    pixelHeight: height, images: images, layouts: layouts,
                                                    options: options, fillWhite: true)
        else { return nil }

        cache[key] = image
        order.append(key)
        if order.count > capacity { cache[order.removeFirst()] = nil }
        return image
    }
}

/// One page (or half a split spread) in the overview: the thumbnail, then a row under it with
/// the position label and the status sticker (kept off the page so it hides none of the art),
/// and selection / drop highlighting.
struct PageThumbnailView: View {
    /// The label row's height and the gap above it; the overview sizes empty slots to match.
    static let labelRowHeight: CGFloat = 20
    static let labelSpacing: CGFloat = 4

    let image: CGImage?
    let part: OverviewPart
    /// Size of one page side, in points.
    let sideSize: CGSize
    /// 1 for a single page or half, 2 for a spread filling both sides.
    let sides: Int
    let status: PageStatus?
    var flags: ImageFlags = []
    let label: String?
    let isSelected: Bool
    let isDropTarget: Bool

    var body: some View {
        let width = sideSize.width * CGFloat(sides)
        VStack(spacing: Self.labelSpacing) {
            ZStack(alignment: .topTrailing) {
                pageImage
                    .frame(width: width, height: sideSize.height)
                    .clipped()
                    .background(.white)
                    .overlay(alignment: .center) {
                        if sides == 2 {
                            // The centre fold.
                            Rectangle().fill(.black.opacity(0.15)).frame(width: 1)
                        }
                    }
                    // A hairline edge, so a white page still reads on a white card (light mode).
                    .overlay { Rectangle().strokeBorder(.black.opacity(0.12), lineWidth: 1) }
                    .shadow(color: Crayon.shadow, radius: 0, x: 0, y: 2)
                if !flags.isEmpty {
                    ImageFlagIcons(flags: flags)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Crayon.card))
                        .shadow(color: Crayon.shadow, radius: 0, x: 0, y: 1.5)
                        .padding(5)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                if part != .single {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Crayon.tomato)
                        .shadow(color: Crayon.shadow, radius: 0, x: 0, y: 1.5)
                        .padding(5)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .help("This spread is split across two sheets.")
                        .accessibilityLabel("Split across two sheets")
                }
            }
            .overlay {
                // Selection (tomato) and drop target (sky) rings, outside the page art.
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(isDropTarget ? Crayon.sky : (isSelected ? Crayon.tomato : .clear),
                                  lineWidth: isDropTarget ? 4 : 3)
                    .padding(-5)
            }
            labelRow.frame(width: width, height: Self.labelRowHeight)
        }
    }

    /// The position label and the status sticker; the sticker shrinks to its symbol when both
    /// don't fit under the page (a long label on a narrow page).
    @ViewBuilder
    private var labelRow: some View {
        let text = label.map { label in
            Text(label)
                .font(Crayon.font(.caption, weight: .bold))
                .foregroundStyle(isSelected ? Crayon.tomato : Crayon.inkSoft)
                .lineLimit(1)
        }
        if let status {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { text; StatusBadge(status: status) }
                HStack(spacing: 6) { text; StatusBadge(status: status, compact: true) }
            }
        } else {
            text
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

/// Empty / In progress / Done (A §4.4), as a crayon sticker: grape for a page not started, sky
/// while it's being drafted, grass once it's done. `compact` shows the symbol only (the page list).
struct StatusBadge: View {
    let status: PageStatus
    var compact = false

    var body: some View {
        let (symbol, color, text): (String, Color, String) = switch status {
        case .empty: ("circle.dashed", Crayon.grape, "Empty")
        case .inProgress: ("circle.lefthalf.filled", Crayon.sky, "In progress")
        case .done: ("checkmark.circle.fill", Crayon.grass, "Done")
        }
        Group {
            if compact {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(color))
                    .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1.5))
                    .shadow(color: Crayon.shadow, radius: 0, x: 0, y: 1.5)
            } else {
                CrayonSticker(text, systemImage: symbol, color: color)
            }
        }
        .help(text)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

/// Compact "Style changed" / "Layout changed" icons with tooltips (A §4.4).
struct ImageFlagIcons: View {
    let flags: ImageFlags

    var body: some View {
        HStack(spacing: 2) {
            ForEach(FlagText.entries(flags), id: \.title) { entry in
                Image(systemName: entry.symbol)
                    .foregroundStyle(entry.color)
                    .help("\(entry.title): \(entry.help)")
                    .accessibilityLabel(entry.title)
            }
        }
    }
}
