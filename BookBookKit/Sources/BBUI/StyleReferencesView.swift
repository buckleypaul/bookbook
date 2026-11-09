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
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Reference images").font(.subheadline)
                Spacer()
                Button("Add…") { showImporter = true }
            }
            if refs.isEmpty {
                Text("Drop images here to show the model the look you want.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 56)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(refs, id: \.sha256) { thumbnail($0) }
                    }
                    .padding(.vertical, 2)
                }
            }
            if let errorText { Text(errorText).font(.caption).foregroundStyle(.red) }
        }
        .padding(6)
        .overlay(RoundedRectangle(cornerRadius: 6)
            .strokeBorder(isTargeted ? Color.accentColor : Color.secondary.opacity(0.3),
                          style: StrokeStyle(lineWidth: isTargeted ? 2 : 1, dash: [4])))
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
                    Color.secondary.opacity(0.2)
                }
            }
            .frame(width: 72, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 4))
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
                    errorText = "Couldn't add \(url.lastPathComponent): \(error)"
                }
            }
            model.addReferences(refs)
        }
    }
}
