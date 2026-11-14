import BBModel
import BBStore
import SwiftUI

/// The logic behind the Style tab (PD §8.2): reads the book's style, and turns each field edit
/// into one `BookCommand` sent through `perform`. No views, so it's testable with closures.
@MainActor @Observable
final class StyleTabModel {
    @ObservationIgnored private let content: @MainActor () -> BookContent
    @ObservationIgnored private let send: @MainActor (BookCommand) -> Void
    /// Bundled presets, in menu order (empty if they fail to load).
    let presets: [StylePreset]

    init(content: @escaping @MainActor () -> BookContent, perform: @escaping @MainActor (BookCommand) -> Void,
         presets: [StylePreset]? = nil) {
        self.content = content
        self.send = perform
        self.presets = presets ?? ((try? Presets.stylePresets()) ?? [])
    }

    convenience init(document: BookDocument) {
        self.init(content: { [unowned document] in document.content },
                  perform: { [unowned document] in _ = document.perform($0) })
    }

    var visual: StyleVisual { content().style.visual }
    var pageSetup: PageSetup { content().style.pageSetup }

    // MARK: Units

    static let pointsPerInch = 72.0

    static func inches(_ points: Double) -> Double { points / pointsPerInch }
    static func points(_ inches: Double) -> Double { inches * pointsPerInch }

    // MARK: Visual style

    /// Fills the description and negative guidance from `preset`. `nil` only clears the preset
    /// ID, leaving the text as it was. References are kept.
    func choosePreset(_ preset: StylePreset?) {
        var v = visual
        guard let preset else {
            v.presetID = nil
            commit(v)
            return
        }
        v.presetID = preset.id
        v.visualDescription = preset.visualDescription
        v.negativeGuidance = preset.negativeGuidance ?? StyleGuide.defaultNegativeGuidance
        commit(v)
    }

    func setDescription(_ text: String) {
        var v = visual
        v.visualDescription = text
        commit(v)
    }

    func setNegativeGuidance(_ text: String) {
        var v = visual
        v.negativeGuidance = text
        commit(v)
    }

    func addReferences(_ refs: [ImageRef]) {
        var v = visual
        let new = refs.filter { !v.styleReferences.contains($0) }
        guard !new.isEmpty else { return }
        v.styleReferences += new
        commit(v)
    }

    func removeReference(_ ref: ImageRef) {
        var v = visual
        v.styleReferences.removeAll { $0 == ref }
        commit(v)
    }

    private func commit(_ v: StyleVisual) {
        guard v != visual else { return }
        send(.setStyleVisual(v))
    }

    // MARK: Page setup

    /// Square sizes have no orientation choice.
    var isSquare: Bool { pageSetup.orientation == .square || pageSetup.sizePreset.isSquarePreset }

    func setSizePreset(_ preset: PageSizePreset) {
        let setup = pageSetup
        guard preset != setup.sizePreset else { return }
        if preset == .custom {
            // Keep the current size as the starting point for the custom fields.
            commit(setup.applying(preset: .custom, orientation: setup.orientation, customSize: setup.trimSize))
        } else {
            // A preset named by its orientation ("10 × 8 in") keeps it; others keep the current one.
            let natural = preset.baseSize.map { $0.width > $0.height ? Orientation.landscape : .portrait }
            let orientation: Orientation = preset == .tenByEight || preset == .eightByTen
                ? (natural ?? .portrait)
                : (setup.orientation == .square ? .portrait : setup.orientation)
            commit(setup.applying(preset: preset, orientation: orientation))
        }
    }

    func setOrientation(_ orientation: Orientation) {
        let setup = pageSetup
        guard orientation != setup.orientation, setup.sizePreset != .custom, !isSquare else { return }
        commit(setup.applying(preset: setup.sizePreset, orientation: orientation))
    }

    func setCustomSize(widthInches: Double? = nil, heightInches: Double? = nil) {
        let setup = pageSetup
        let w = widthInches.map(Self.points) ?? setup.trimSize.width
        let h = heightInches.map(Self.points) ?? setup.trimSize.height
        guard w >= 72, h >= 72, w <= 72 * 40, h <= 72 * 40 else { return }
        commit(setup.applying(preset: .custom, orientation: setup.orientation,
                              customSize: PointSize(width: w, height: h)))
    }

    /// Sets the margins on all four edges, in inches. Capped at a third of the smaller page side.
    func setMargins(inches: Double) {
        var setup = pageSetup
        let limit = min(setup.trimSize.width, setup.trimSize.height) / 3
        setup.margins = EdgeInsetsPt(all: min(max(0, Self.points(inches)), limit))
        commit(setup)
    }

    func setBleedEnabled(_ on: Bool) {
        var setup = pageSetup
        setup.bleedEnabled = on
        commit(setup)
    }

    func setBleedAmount(inches: Double) {
        var setup = pageSetup
        let pts = min(max(0, Self.points(inches)), 36)
        guard pts > 0 else { return }
        setup.bleedAmount = pts
        commit(setup)
    }

    private func commit(_ setup: PageSetup) {
        guard setup != pageSetup else { return }
        send(.setPageSetup(setup))
    }

    // MARK: Flags

    func markOK(page: PageID, box: BoxID?) { send(.markFlagsOK(page: page, box: box)) }
}

extension PageSizePreset {
    var isSquarePreset: Bool { self == .square8 || self == .square8_5 }
}

/// Plain-language names and symbols for image flags.
enum FlagText {
    struct Entry {
        var symbol: String
        var color: Color
        var title: String
        var help: String
    }

    static func entries(_ flags: ImageFlags) -> [Entry] {
        var out: [Entry] = []
        if flags.contains(.styleChanged) {
            out.append(Entry(symbol: "paintpalette.fill", color: Crayon.grape, title: "Style changed",
                             help: "The book's visual style changed after this image was made."))
        }
        if flags.contains(.assetChanged) {
            out.append(Entry(symbol: "person.crop.square.fill", color: Crayon.bubblegum, title: "Asset changed",
                             help: "A character, prop or place used for this image was edited after it was made."))
        }
        if flags.contains(.layoutChanged) {
            out.append(Entry(symbol: "rectangle.dashed", color: Crayon.sunflower, title: "Layout changed",
                             help: "This box's shape changed since the image was placed."))
        }
        if flags.contains(.consistencyWarning) {
            out.append(Entry(symbol: "person.2.slash.fill", color: Crayon.tomato, title: "Consistency warning",
                             help: "A consistency check found this picture differs from the references. Open the session to fix or dismiss it."))
        }
        return out
    }

    static func summary(_ flags: ImageFlags) -> String {
        entries(flags).map(\.title).joined(separator: ", ")
    }
}

/// The Style tab's sections, in form order. The sidebar lists them; choosing one scrolls the form.
enum StyleSection: String, CaseIterable, Identifiable {
    case visual, typography, pageSetup
    var id: String { rawValue }
    var title: String {
        switch self { case .visual: "Visual style"; case .typography: "Typography and page numbers"; case .pageSetup: "Page setup" }
    }
    var symbol: String {
        switch self { case .visual: "paintbrush.pointed"; case .typography: "textformat"; case .pageSetup: "doc.plaintext" }
    }
    var color: Color {
        switch self { case .visual: Crayon.grape; case .typography: Crayon.sky; case .pageSetup: Crayon.grass }
    }
}

extension Notification.Name {
    /// Posted (object: the `StyleSection`) each time a Style sidebar row is clicked.
    static let styleSectionChosen = Notification.Name("BookBook.styleSectionChosen")
}

/// The Style tab's sidebar: one row per form section.
struct StyleSectionList: View {
    @Binding var selection: StyleSection

    var body: some View {
        List(selection: Binding(get: { selection }, set: { if let s = $0 { selection = s } })) {
            ForEach(StyleSection.allCases) { section in
                Label {
                    Text(section.title).font(Crayon.font(.body, weight: .semibold)).foregroundStyle(Crayon.ink)
                } icon: {
                    Image(systemName: section.symbol).foregroundStyle(section.color)
                }
                .tag(section)
                .listRowSeparator(.hidden)
                .contentShape(Rectangle())
                // Choosing the section that's already selected doesn't change the selection, so
                // tell the form to scroll there anyway.
                .onTapGesture {
                    selection = section
                    NotificationCenter.default.post(name: .styleSectionChosen, object: section)
                }
            }
        }
    }
}

/// The Style tab's main area: visual style, typography, then page setup. `section` is the one
/// chosen in the sidebar; changing it scrolls there.
struct StyleTab: View {
    let document: BookDocument
    let model: StyleTabModel
    var section: StyleSection = .visual
    let onEditPageNumbers: () -> Void
    @State private var showTypography = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollViewReader { proxy in
            form
                .onChange(of: section) { _, target in scroll(proxy, to: target) }
                .onReceive(NotificationCenter.default.publisher(for: .styleSectionChosen)) { note in
                    if let target = note.object as? StyleSection { scroll(proxy, to: target) }
                }
        }
    }

    /// Scrolls to `target`, without animation when Reduce Motion is on.
    private func scroll(_ proxy: ScrollViewProxy, to target: StyleSection) {
        if reduceMotion {
            proxy.scrollTo(target, anchor: .top)
        } else {
            withAnimation { proxy.scrollTo(target, anchor: .top) }
        }
    }

    private var form: some View {
        Form {
            Section {
                presetPicker
                VStack(alignment: .leading, spacing: 4) {
                    StyleFieldTitle("Description")
                    CommitTextEditor(text: model.visual.visualDescription, minHeight: 90) { model.setDescription($0) }
                    Text("Describes the look of every image. Placed images are flagged “Style changed” when this, the references or the negative guidance change.")
                        .font(.caption).foregroundStyle(Crayon.inkSoft)
                }
                StyleReferencesView(document: document, model: model)
                VStack(alignment: .leading, spacing: 4) {
                    StyleFieldTitle("Negative guidance")
                    CommitTextEditor(text: model.visual.negativeGuidance, minHeight: 50) { model.setNegativeGuidance($0) }
                }
            } header: {
                CrayonHeader(StyleSection.visual.title, color: StyleSection.visual.color)
            }
            .disabled(!document.isEditable)
            .id(StyleSection.visual)
            Section {
                HStack(spacing: 8) {
                    Button("Edit Typography…") { showTypography = true }
                    Button("Edit Page Numbers…") { onEditPageNumbers() }
                }
                .buttonBorderShape(.capsule)
                Text("Typography and page setup changes don't mark images as style changed.")
                    .font(.caption).foregroundStyle(Crayon.inkSoft)
            } header: {
                CrayonHeader(StyleSection.typography.title, color: StyleSection.typography.color)
            }
            .id(StyleSection.typography)
            PageSetupForm(model: model, isEditable: document.isEditable)
                .id(StyleSection.pageSetup)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .crayonPaper()
        .sheet(isPresented: $showTypography) { TypographyForm(document: document) }
    }

    @ViewBuilder
    private var presetPicker: some View {
        Picker("Preset", selection: Binding(
            get: { model.visual.presetID ?? "" },
            set: { id in model.choosePreset(model.presets.first { $0.id == id }) })) {
            Text("None").tag("")
            ForEach(model.presets) { Text($0.name).tag($0.id) }
        }
        if let preset = model.presets.first(where: { $0.id == model.visual.presetID }), preset.sampleImageURL != nil {
            PresetSampleImage(preset: preset, size: 96)
        }
    }
}

/// A multi-line text field that commits when it loses focus (so typing isn't one undo step per
/// keystroke), and follows model changes (undo) even while focused, and commits only a differing draft.
struct CommitTextEditor: View {
    let text: String
    var minHeight: CGFloat = 60
    let commit: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextEditor(text: $draft)
            .focused($focused)
            .crayonTextEditor(focused: focused, minHeight: minHeight)
            .committingDraft($draft, of: text, focused: focused, commit: commit)
    }
}

/// A field title inside a Style tab section, in rounded bold type.
private struct StyleFieldTitle: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title).font(Crayon.font(.subheadline, weight: .bold)).foregroundStyle(Crayon.ink)
    }
}
