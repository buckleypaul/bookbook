import BBModel
import SwiftUI

/// A chosen-image thumbnail, or an empty state.
struct AssetThumbnail: View {
    let ref: ImageRef?
    let images: ImageCache
    var size: CGFloat = 56
    /// A coloured avatar ring around the thumbnail (the asset's colour); nil for none.
    var ring: Color?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: min(Crayon.mediumCornerRadius, size * 0.28), style: .continuous)
        // A small decode: the thumbnail never needs `images`' full-size one.
        let cg = ref.flatMap { images.previews.image(for: $0) }
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
        .overlay {
            if let ring {
                shape.strokeBorder(ring, lineWidth: size >= 48 ? 3 : 2).padding(-(size >= 48 ? 3 : 2))
            }
        }
        .padding(ring == nil ? 0 : (size >= 48 ? 3 : 2))
    }
}

/// An asset image shown as large as the window allows, fitted, on paper.
struct ImagePreviewSheet: View {
    let title: String
    let image: CGImage

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
    }
}
