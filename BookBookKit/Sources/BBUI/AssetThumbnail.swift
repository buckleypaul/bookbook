import BBModel
import SwiftUI

/// A chosen-image thumbnail, or an empty state. When `expandTitle` is set and there's an image,
/// hovering shows a button (and the context menu an item) that opens it larger in a sheet.
struct AssetThumbnail: View {
    let ref: ImageRef?
    let images: ImageCache
    var size: CGFloat = 56
    /// A coloured avatar ring around the thumbnail (the asset's colour); nil for none.
    var ring: Color?
    /// The enlarged view's title; nil = not expandable.
    var expandTitle: String?
    @State private var hovering = false
    @State private var expanded: ExpandedImage?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: min(Crayon.mediumCornerRadius, size * 0.28), style: .continuous)
        // A small decode for the thumbnail itself; the enlarged view uses `images`' full-size one.
        let cg = ref.flatMap { images.previews.image(for: $0) }
        let canExpand = expandTitle != nil && cg != nil
        ZStack {
            shape.fill(Crayon.paperDeep)
            if let cg {
                Image(decorative: cg, scale: 1).resizable().scaledToFill()
            } else {
                Image(systemName: "photo").foregroundStyle(Crayon.inkSoft.opacity(0.7))
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(alignment: .bottomTrailing) {
            if canExpand, hovering, let cg {
                Button { expand(cg) } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: size >= 48 ? 11 : 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(size >= 48 ? 5 : 3)
                        .background(Circle().fill(.black.opacity(0.55)))
                }
                .buttonStyle(.plain)
                .padding(size >= 48 ? 4 : 2)
                .help("View larger")
                .accessibilityLabel("View larger")
            }
        }
        .overlay {
            if let ring {
                shape.strokeBorder(ring, lineWidth: size >= 48 ? 3 : 2).padding(-(size >= 48 ? 3 : 2))
            }
        }
        .padding(ring == nil ? 0 : (size >= 48 ? 3 : 2))
        .onHover { hovering = $0 }
        .contextMenu {
            if canExpand, let cg {
                Button("View Larger", systemImage: "arrow.up.left.and.arrow.down.right") {
                    expand(cg)
                }
            }
        }
        .accessibilityAction(named: "View larger") { if canExpand, let cg { expand(cg) } }
        .sheet(item: $expanded) { item in
            ImagePreviewSheet(title: expandTitle ?? "", image: item.image)
        }
    }

    /// Opens the enlarged view on the full-size image (the `preview` if that can't be read).
    private func expand(_ preview: CGImage) {
        expanded = ExpandedImage(image: ref.flatMap { images.image(for: $0) } ?? preview)
    }
}

private struct ExpandedImage: Identifiable {
    let id = UUID()
    let image: CGImage
}

/// An asset image shown as large as the window allows, fitted, on paper.
struct ImagePreviewSheet: View {
    let title: String
    let image: CGImage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                CrayonHeader(title, color: Crayon.sky).lineLimit(1)
                Spacer()
                Text("\(image.width) × \(image.height)")
                    .font(.caption).monospacedDigit().foregroundStyle(Crayon.inkSoft)
            }
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel(title)
            CrayonSheetDoneFooter()
        }
        // Sheets open at their minimum size (an ideal size does nothing), so the minimum is what
        // makes this "larger" than the inline thumbnail.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .crayonSheet(minWidth: 720, minHeight: 720)
        .onExitCommand { dismiss() }
    }
}
