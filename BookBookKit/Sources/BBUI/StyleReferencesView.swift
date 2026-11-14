import BBModel
import SwiftUI
import UniformTypeIdentifiers

/// The style reference images: thumbnails with remove buttons, Add… (open panel) and drag-in.
struct StyleReferencesView: View {
    let document: BookDocument
    let model: StyleTabModel
    @State private var showImporter = false
    @State private var isTargeted = false
    @State private var errorText: String?
    @State private var cache: ImageCache
    @State private var preview: PreviewImage?

    init(document: BookDocument, model: StyleTabModel) {
        self.document = document
        self.model = model
        _cache = State(initialValue: ImageCache(store: document.store, maxPixelSize: 256))
    }

    private static let types: [UTType] = [.png, .jpeg, .heic] + (UTType("org.webmproject.webp").map { [$0] } ?? [])

    var body: some View {
        let refs = model.visual.styleReferences
        let shape = RoundedRectangle(cornerRadius: Crayon.mediumCornerRadius, style: .continuous)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Reference images").font(Crayon.font(.subheadline, weight: .bold)).foregroundStyle(Crayon.ink)
                Spacer()
                Button("Add…") { showImporter = true }
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
            }
            if refs.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(Crayon.grape)
                        .accessibilityHidden(true)
                    Text("Drop images here to show the model the look you want.")
                        .font(Crayon.font(.caption, weight: .medium)).foregroundStyle(Crayon.inkSoft)
                }
                .frame(maxWidth: .infinity, minHeight: 56)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        ForEach(Array(refs.enumerated()), id: \.element.sha256) { thumbnail($1, number: $0 + 1) }
                    }
                    .padding(.horizontal, 2)
                    .padding(.top, 4)
                    .padding(.bottom, 8)
                }
            }
            if let errorText {
                Text(errorText).font(Crayon.font(.caption, weight: .semibold)).foregroundStyle(Crayon.danger)
            }
        }
        .padding(8)
        .background((isTargeted ? Crayon.tomato.opacity(0.08) : Crayon.paperDeep.opacity(0.6)), in: shape)
        .overlay(shape
            .strokeBorder(isTargeted ? Crayon.tomato : Crayon.ink.opacity(0.18),
                          style: StrokeStyle(lineWidth: isTargeted ? 2.5 : 1.5, dash: [6, 4])))
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            add(files)
            return !files.isEmpty
        } isTargeted: { isTargeted = $0 }
        .sheet(item: $preview) { item in
            ImagePreviewSheet(title: "Style reference \(item.number)", image: item.image)
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: Self.types, allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): add(urls)
            case .failure(let error): errorText = error.localizedDescription
            }
        }
    }

    /// A reference image enlarged in `ImagePreviewSheet`.
    private struct PreviewImage: Identifiable {
        let id = UUID()
        let number: Int
        let image: CGImage
    }

    private func expand(_ ref: ImageRef, number: Int) {
        // The row's cache is downsampled; the enlarged view reads the full-size image.
        let full = ImageCache(store: document.store, maxPixelSize: nil)
        guard let image = full.image(for: ref) ?? cache.image(for: ref) else { return }
        preview = PreviewImage(number: number, image: image)
    }

    private func thumbnail(_ ref: ImageRef, number: Int) -> some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let image = cache.image(for: ref) {
                    Image(decorative: image, scale: 1).resizable().scaledToFill()
                } else {
                    Crayon.paperDeep
                }
            }
            .frame(width: 72, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: Crayon.thumbCornerRadius, style: .continuous))
            .crayonCard(cornerRadius: Crayon.smallCornerRadius, padding: 3)
            .onTapGesture(count: 2) { expand(ref, number: number) }
            .contextMenu {
                Button("View Larger", systemImage: "arrow.up.left.and.arrow.down.right") {
                    expand(ref, number: number)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Style reference image \(number)")
            .accessibilityAction(named: "View larger") { expand(ref, number: number) }
            Button { model.removeReference(ref) } label: {
                Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.6))
            }
            .buttonStyle(.plain)
            .help("Remove this reference image")
            .accessibilityLabel("Remove reference image \(number)")
            .padding(2)
        }
    }

    private func add(_ urls: [URL]) {
        errorText = nil
        Task {
            var refs: [ImageRef] = []
            for url in urls {
                do { refs.append(try await document.storeStyleReference(from: url)) } catch {
                    errorText = "Couldn't add \(url.lastPathComponent). \(ImageImportFailure.message(for: error))"
                }
            }
            model.addReferences(refs)
        }
    }
}
