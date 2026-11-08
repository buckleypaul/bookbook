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
    let onExport: (Version) -> Void
    let onDelete: (Version) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(Array(session.versions.enumerated()), id: \.element.id) { index, version in
                    cell(version, number: index + 1)
                }
            }
            .padding(4)
        }
    }

    private func cell(_ version: Version, number: Int) -> some View {
        let placed = version.id == placedID
        let selected = version.id == selectedID
        return Button {
            onChoose(version)
        } label: {
            VStack(spacing: 3) {
                VersionThumbnail(ref: version.image, url: store.imageURL(for: version.image))
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.3),
                                      lineWidth: selected ? 3 : 1))
                    .overlay(alignment: .topTrailing) { starButton(version) }
                    .overlay(alignment: .bottomLeading) {
                        if placed {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.white, Color.accentColor)
                                .padding(3)
                                .help("On the page")
                        }
                    }
                Text("v\(number)").font(.caption2).monospacedDigit()
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(version.starred ? "Remove Star" : "Star") { onToggleStar(version) }
            Button("Export Image…") { onExport(version) }
            Divider()
            Button("Delete Version…", role: .destructive) { onDelete(version) }
        }
        .help(placed ? "Version \(number) (on the page)" : "Put version \(number) on the page")
        .accessibilityLabel("Version \(number)\(placed ? ", on the page" : "")\(version.starred ? ", starred" : "")")
    }

    private func starButton(_ version: Version) -> some View {
        Button {
            onToggleStar(version)
        } label: {
            Image(systemName: version.starred ? "star.fill" : "star")
                .font(.caption)
                .foregroundStyle(version.starred ? Color.yellow : Color.white)
                .shadow(radius: 1)
                .padding(3)
        }
        .buttonStyle(.plain)
        .help(version.starred ? "Remove star" : "Star this version")
        .accessibilityLabel(version.starred ? "Remove star" : "Star")
    }
}

/// A small thumbnail decoded off the main thread.
struct VersionThumbnail: View {
    let ref: ImageRef
    let url: URL
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
            } else {
                Rectangle().fill(.quaternary).overlay(Image(systemName: "photo").foregroundStyle(.secondary))
            }
        }
        .task(id: ref) {
            let url = url
            image = await Task.detached(priority: .utility) { Self.decode(url) }.value
        }
    }

    nonisolated private static func decode(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 192,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
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
        let title = book.isEmpty ? "BookBook" : book
        let safe = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return "\(safe) \(pageText) v\(number).\(ref.fileExtension)"
    }

    /// Returns an error text, or nil if the copy happened or the user cancelled.
    static func run(ref: ImageRef, from source: URL, suggestedName: String) -> String? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        if let type = UTType(ref.contentType) { panel.allowedContentTypes = [type] }
        guard panel.runModal() == .OK, let destination = panel.url else { return nil }
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
