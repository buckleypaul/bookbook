import AppKit
import BBLayout
import BBModel
import SwiftUI
import UniformTypeIdentifiers

/// The book's typography (PD §8.2): body and title font, default size, colour, line spacing and
/// alignment. The full Style tab is Phase 7; this form is reached from the toolbar and the
/// Format menu. Each change is one `.setTypography`: pickers commit at once, text fields on
/// return or focus loss, sliders when the drag ends, the colour after a short pause.
struct TypographyForm: View {
    let document: BookDocument
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Typography
    @State private var sizeText: String
    @State private var colorTask: Task<Void, Never>?
    @State private var showImporter = false
    @State private var alert: FontAlert?
    /// Bumped after a font import so the pickers re-read the installed families.
    @State private var fontsEpoch = 0
    @FocusState private var sizeFocused: Bool

    struct FontAlert: Identifiable {
        let id = UUID()
        var title: String
        var message: String
    }

    init(document: BookDocument) {
        self.document = document
        let t = document.content.style.typography
        _draft = State(initialValue: t)
        _sizeText = State(initialValue: String(format: "%g", t.bodySize))
    }

    private var current: Typography { document.content.style.typography }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CrayonHeader("Typography", color: Crayon.grape)
            Form {
                fontPicker("Body font", selection: $draft.bodyFont)
                fontPicker("Title font", selection: $draft.titleFont)
                TextField("Default size (pt)", text: $sizeText)
                    .focused($sizeFocused)
                    .onSubmit(commitSize)
                    .onChange(of: sizeFocused) { _, focused in if !focused { commitSize() } }
                ColorPicker("Colour", selection: Binding(
                    get: { draft.color.swiftUIColor },
                    set: { draft.color = RGBA(color: $0); scheduleColorCommit() }),
                    supportsOpacity: false)
                LabeledContent("Line spacing") {
                    HStack {
                        Slider(value: $draft.lineSpacing, in: 0.8...2.5, onEditingChanged: { editing in
                            if !editing { commit() }
                        })
                        Text(String(format: "%.2f", draft.lineSpacing)).monospacedDigit().frame(width: 40)
                    }
                }
                LabeledContent("Alignment") {
                    Picker("Alignment", selection: $draft.alignment) {
                        Text("Left").tag(BBModel.TextAlignment.leading)
                        Text("Centre").tag(BBModel.TextAlignment.center)
                        Text("Right").tag(BBModel.TextAlignment.trailing)
                        Text("Justified").tag(BBModel.TextAlignment.justified)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }
            .disabled(!document.isEditable)
            if !document.missingFonts.isEmpty {
                Text("Missing: \(document.missingFonts.joined(separator: ", "))")
                    .font(.caption).foregroundStyle(Crayon.inkSoft)
            }
            CrayonSheetDoneFooter(color: Crayon.grape, action: { finish() }, leading: {
                Button("Import Font…") { showImporter = true }
                    .disabled(!document.isEditable)
            })
        }
        .crayonSheet(width: 420)
        .onExitCommand { finish() }
        .onChange(of: current) { _, new in
            draft = new
            sizeText = String(format: "%g", new.bodySize)
        }
        // Escape or a click-away closes the sheet without `Done`: keep a typed size and any
        // pending colour, and stop the colour timer so nothing fires afterwards.
        .onDisappear { flush() }
        .onChange(of: draft.bodyFont) { commit() }
        .onChange(of: draft.titleFont) { commit() }
        .onChange(of: draft.alignment) { commit() }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: Self.fontTypes) { result in
            switch result {
            case .success(let url): importFont(url)
            case .failure(let error):
                alert = FontAlert(title: "Couldn't import the font", message: StoreErrorText.message(for: error))
            }
        }
        .alert(alert?.title ?? "", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } }),
               presenting: alert) { _ in
            Button("OK", role: .cancel) {}
        } message: { Text($0.message) }
    }

    static let fontTypes: [UTType] =
        [.font] + ["ttf", "otf", "ttc"].compactMap { UTType(filenameExtension: $0) }

    private func fontPicker(_ title: String, selection: Binding<FontRef>) -> some View {
        _ = fontsEpoch
        let name = selection.wrappedValue.postScriptName
        let family = FontFamilies.family(of: name)
        return Picker(title, selection: Binding(
            get: { family ?? name },
            set: { newFamily in
                if let face = FontFamilies.regularFace(of: newFamily) {
                    selection.wrappedValue = FontRef(postScriptName: face)
                }
            })) {
            if family == nil { Text("\(name) (missing)").tag(name) }
            ForEach(FontFamilies.all, id: \.self) { Text($0).tag($0) }
        }
    }

    private func commitSize() {
        if let size = Double(sizeText.trimmingCharacters(in: .whitespaces)), size >= 4, size <= 200 {
            draft.bodySize = size
            commit()
        }
        sizeText = String(format: "%g", draft.bodySize)
    }

    private func scheduleColorCommit() {
        colorTask?.cancel()
        colorTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            if !Task.isCancelled { commit() }
        }
    }

    private func commit() {
        guard draft != current else { return }
        document.perform(.setTypography(draft))
    }

    private func flush() {
        colorTask?.cancel()
        colorTask = nil
        guard document.isEditable else { return }
        commitSize()
        commit()
    }

    private func finish() {
        flush()
        dismiss()
    }

    private func importFont(_ url: URL) {
        Task {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let info = try await document.importFont(from: url)
                fontsEpoch += 1
                if !info.embeddingAllowed {
                    alert = FontAlert(
                        title: "This font can't be embedded",
                        message: "\(info.familyName)'s licence doesn't allow embedding it in a PDF. It will show on screen, but exported PDFs can't include it.")
                }
            } catch {
                alert = FontAlert(title: "Couldn't import the font", message: StoreErrorText.message(for: error))
            }
        }
    }
}
