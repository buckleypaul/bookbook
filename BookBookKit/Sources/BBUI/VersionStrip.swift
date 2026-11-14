import AppKit
import BBModel
import BBStore
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// The session's versions as thumbnails (PD §8.6): "vN", a star toggle, click to put the
/// version on the page and select it. Delete and export are in the context menu and in the
/// panel's action row.
struct VersionStrip: View {
    let session: Session
    let placedID: VersionID?
    let selectedID: VersionID?
    let store: BookStore
    let onChoose: (Version) -> Void
    let onToggleStar: (Version) -> Void
    /// Nil leaves "Export Image…" out of the context menu.
    var onExport: ((Version) -> Void)?
    /// Nil leaves "Edit Region…" out of the context menu (text styles).
    var onEditRegion: ((Version) -> Void)?
    var regionEditReason: (Version) -> String? = { _ in nil }
    let onDelete: (Version) -> Void
    /// False for a read-only book: starring and deleting are unavailable.
    var isEditable: Bool = true
    /// Whether a consistency check of the version is waiting or running.
    var isChecking: (Version) -> Bool = { _ in false }

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 12) {
                ForEach(Array(session.versions.enumerated()), id: \.element.id) { index, version in
                    cell(version, number: index + 1)
                }
            }
            // Room for the card shadows and the hover lift.
            .padding(.horizontal, 6)
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
    }

    /// A picture's thumbnail; for an AI text style (A §7.13), its decoration on paper with an
    /// "Aa" sample in the style's font and colour.
    @ViewBuilder
    private func thumbnail(_ version: Version) -> some View {
        if let style = version.textStyle {
            ZStack {
                Color.white
                if style.decorationPrompt != nil {
                    VersionThumbnail(ref: version.image, url: store.imageURL(for: version.image))
                }
                Text("Aa")
                    .font(style.styling.font.map { Font.custom($0.postScriptName, size: 20) } ?? .system(size: 20))
                    .foregroundStyle(style.styling.color.map {
                        Color(.sRGB, red: $0.red, green: $0.green, blue: $0.blue, opacity: $0.alpha)
                    } ?? Crayon.ink)
                    .padding(4)
                    .background(style.styling.background.map {
                        Color(.sRGB, red: $0.red, green: $0.green, blue: $0.blue, opacity: $0.alpha)
                    } ?? .clear, in: RoundedRectangle(cornerRadius: 4))
            }
        } else {
            VersionThumbnail(ref: version.image, url: store.imageURL(for: version.image))
        }
    }

    private func cell(_ version: Version, number: Int) -> some View {
        let placed = version.id == placedID
        let selected = version.id == selectedID
        return Button {
            onChoose(version)
        } label: {
            VStack(spacing: 4) {
                thumbnail(version)
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: Crayon.thumbCornerRadius, style: .continuous))
                    .overlay(alignment: .topTrailing) { starButton(version) }
                    .overlay(alignment: .bottomTrailing) { consistencyBadge(version) }
                    .overlay(alignment: .bottomLeading) {
                        if placed {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.callout.weight(.bold))
                                .foregroundStyle(.white, Crayon.grass)
                                .shadow(color: Crayon.shadow, radius: 0, x: 0, y: 1)
                                .padding(3)
                                .help("On the page")
                        }
                    }
                Text("v\(number)")
                    .font(Crayon.font(.caption2, weight: .heavy)).monospacedDigit()
                    .foregroundStyle(selected ? Crayon.tomato : Crayon.inkSoft)
            }
            .crayonCard(selected: selected, tint: Crayon.tomato, cornerRadius: Crayon.mediumCornerRadius, padding: 4)
            .crayonHover(tilt: number.isMultiple(of: 2) ? 2 : -2)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(version.starred ? "Remove Star" : "Star Version") { onToggleStar(version) }
                .disabled(!isEditable)
            if let onExport {
                Button("Export Image…") { onExport(version) }
            }
            if let onEditRegion {
                Button("Edit Region…") { onEditRegion(version) }
                    .disabled(regionEditReason(version) != nil)
            }
            Divider()
            Button("Delete Version…", role: .destructive) { onDelete(version) }
                .disabled(!isEditable)
        }
        .help(placed ? "Version \(number) (on the page)" : "Put version \(number) on the page")
        .accessibilityLabel("Version \(number)\(placed ? ", on the page" : "")\(version.starred ? ", starred" : "")\(version.consistency?.showsWarning == true ? ", consistency warning" : "")")
    }

    @ViewBuilder
    private func consistencyBadge(_ version: Version) -> some View {
        if isChecking(version) {
            ProgressView().controlSize(.mini).padding(3)
                .help("Checking consistency…")
                .accessibilityLabel("Checking consistency")
        } else if version.consistency?.showsWarning == true {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Crayon.onSunflower, Crayon.sunflower)
                .shadow(color: Crayon.shadow, radius: 0, x: 0, y: 1)
                .padding(3)
                .help("This picture differs from the references. Select this version to see the differences and fix or dismiss them.")
                .accessibilityLabel("Consistency warning")
        }
    }

    private func starButton(_ version: Version) -> some View {
        Button {
            onToggleStar(version)
        } label: {
            Image(systemName: version.starred ? "star.fill" : "star")
                .font(.caption.weight(.bold))
                .foregroundStyle(version.starred ? Crayon.sunflower : Color.white)
                .shadow(color: .black.opacity(0.45), radius: 1)
                .padding(3)
        }
        .buttonStyle(.plain)
        .disabled(!isEditable)
        .help(version.starred ? "Remove star" : "Star version")
        .accessibilityLabel(version.starred ? "Remove star" : "Star version")
    }
}

/// A small thumbnail decoded off the main thread, once per image (`VersionThumbnailCache`).
struct VersionThumbnail: View {
    let ref: ImageRef
    let url: URL
    @State private var decoded: Decoded?

    /// The last decode and the ref it was for, so a view reused for another ref never shows the
    /// previous ref's picture (while the new one decodes, or if its decode fails).
    struct Decoded {
        let ref: ImageRef
        let image: CGImage?

        /// The decoded image if it's for `ref`.
        func image(for ref: ImageRef) -> CGImage? { ref == self.ref ? image : nil }
    }

    var body: some View {
        Group {
            if let image = VersionThumbnailCache.image(for: ref) ?? decoded?.image(for: ref) {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
            } else {
                Rectangle().fill(Crayon.paperDeep).overlay(Image(systemName: "photo").foregroundStyle(Crayon.inkSoft))
            }
        }
        .task(id: ref) {
            let ref = ref
            if let cached = VersionThumbnailCache.image(for: ref) {
                decoded = Decoded(ref: ref, image: cached)
                return
            }
            let url = url
            let image = await Task.detached(priority: .utility) { Self.decode(url) }.value
            if let image { VersionThumbnailCache.insert(image, for: ref) }
            decoded = Decoded(ref: ref, image: image)
        }
    }

    nonisolated private static func decode(_ url: URL) -> CGImage? {
        ImageCache.load(url, maxPixelSize: 192)
    }
}

/// Decoded version thumbnails, shared by every strip and picker. Image files are
/// content-addressed and never change, so a thumbnail stays right for its `ImageRef`; the
/// cache only saves decoding again (the panel is rebuilt on every box selection). A failed
/// decode isn't cached: the file may be written a moment later.
@MainActor
enum VersionThumbnailCache {
    private static let cache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.totalCostLimit = 32 << 20  // bytes: about 200 thumbnails of 192 px
        return cache
    }()

    static func image(for ref: ImageRef) -> CGImage? { cache.object(forKey: key(ref)) }

    static func insert(_ image: CGImage, for ref: ImageRef) {
        cache.setObject(image, forKey: key(ref), cost: image.bytesPerRow * image.height)
    }

    private static func key(_ ref: ImageRef) -> NSString { "\(ref.sha256).\(ref.contentType)" as NSString }
}

/// "Export Image…": copies the stored file to a place the user picks.
@MainActor
enum VersionExport {
    /// "<book> p<n> v<N>.png", with `cover` for the cover.
    static func suggestedName(book: String, page: PageID, in content: BookContent, number: Int,
                              ref: ImageRef) -> String {
        let pageText = page == content.book.coverPageID
            ? "cover"
            : content.book.pageOrder.firstIndex(of: page).map { "p\($0 + 1)" } ?? "page"
        let safe = SafeFileName.make(book, fallback: "BookBook")
        return "\(safe) \(pageText) v\(number).\(ref.fileExtension)"
    }

    /// Returns an error text, or nil if the copy happened or the user cancelled.
    static func run(ref: ImageRef, from source: URL, suggestedName: String) -> String? {
        let panel = NSSavePanel()
        ExportPanel.configure(panel)
        panel.nameFieldStringValue = suggestedName
        if let type = UTType(ref.contentType) { panel.allowedContentTypes = [type] }
        guard panel.runModal() == .OK, let destination = panel.url else { return nil }
        ExportPanel.remember(destination)
        do {
            let fm = FileManager.default
            if fm.fileExists(atPath: destination.path(percentEncoded: false)) {
                try fm.removeItem(at: destination)
            }
            try fm.copyItem(at: source, to: destination)
            return nil
        } catch {
            return "The image couldn't be exported: \(error.localizedDescription)"
        }
    }
}
