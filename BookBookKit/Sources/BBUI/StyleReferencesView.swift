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

    init(document: BookDocument, model: StyleTabModel) {
        self.document = document
        self.model = model
        _cache = State(initialValue: ImageCache(store: document.store, maxPixelSize: 256))
    }

    private static let types: [UTType] = [.png, .jpeg, .heic] + (UTType("org.webmproject.webp").map { [$0] } ?? [])

    var body: some View {
        let refs = model.visual.styleReferences
        let shape = RoundedRectangle(cornerRadius: Crayon.smallCornerRadius + 2, style: .continuous)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Reference images").font(Crayon.font(.subheadline, weight: .bold)).foregroundStyle(Crayon.ink)
                Spacer()
                Button("Add…") { showImporter = true }
                    .buttonStyle(.crayon(Crayon.sky))
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
                        ForEach(refs, id: \.sha256) { thumbnail($0) }
                    }
                    .padding(.horizontal, 2)
                    .padding(.top, 4)
                    .padding(.bottom, 8)
                }
            }
            if let errorText {
                Text(errorText).font(Crayon.font(.caption, weight: .semibold)).foregroundStyle(Crayon.tomato)
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
        .fileImporter(isPresented: $showImporter, allowedContentTypes: Self.types, allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): add(urls)
            case .failure(let error): errorText = error.localizedDescription
            }
        }
    }

    private func thumbnail(_ ref: ImageRef) -> some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let image = cache.image(for: ref) {
                    Image(decorative: image, scale: 1).resizable().scaledToFill()
                } else {
                    Crayon.paperDeep
                }
            }
            .frame(width: 72, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: Crayon.smallCornerRadius - 2, style: .continuous))
            .crayonCard(cornerRadius: Crayon.smallCornerRadius, padding: 3)
            Button { model.removeReference(ref) } label: {
                Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.6))
            }
            .buttonStyle(.plain)
            .help("Remove this reference image")
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
