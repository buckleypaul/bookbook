import AppKit
import BBModel
import BBStore
import SwiftUI

/// The logic behind the new-book wizard (PD §8.13): which step is up, and the `NewBookSpec` the
/// choices add up to. Every step is skippable; skipping resets that step to its default. No views,
/// so it's testable.
@MainActor @Observable
final class NewBookWizardModel {
    enum Step: Int, CaseIterable {
        case title, pageSize, style, character, story
    }

    private(set) var step: Step = .title
    /// Starts empty; the field's prompt says "Untitled" and `NewBookSpec.resolvedTitle` falls back to it.
    var title = ""
    var author = ""
    /// Sizes named by their orientation (10 × 8 in is landscape by name) pick it, so the book
    /// comes out as the size the menu said. Other sizes keep the current choice, like the Style tab.
    var pageSize: PageSizePreset = .usLetter {
        didSet {
            if pageSize != oldValue, pageSize == .tenByEight || pageSize == .eightByTen {
                orientation = Self.naturalOrientation(of: pageSize)
            }
        }
    }
    var orientation: Orientation = .portrait
    var stylePresetID: String?
    var characterName = ""
    var characterDescription = ""
    var importStory: Bool
    /// Bundled presets, in menu order (empty if they fail to load).
    let presets: [StylePreset]

    init(importStory: Bool = false, presets: [StylePreset]? = nil) {
        self.importStory = importStory
        self.presets = presets ?? ((try? Presets.stylePresets()) ?? [])
    }

    var isFirst: Bool { step == .title }
    var isLast: Bool { step == .story }

    /// Page sizes are the presets with a fixed size (custom sizes are set in the Style tab).
    static var pageSizes: [PageSizePreset] { PageSizePreset.allCases.filter { $0 != .custom } }

    /// Square sizes have no orientation choice.
    var orientationApplies: Bool { !pageSize.isSquarePreset }

    /// The orientation a preset is named in: landscape when its base size is wider than tall.
    static func naturalOrientation(of preset: PageSizePreset) -> Orientation {
        guard let base = preset.baseSize else { return .portrait }
        return base.width > base.height ? .landscape : .portrait
    }

    func next() {
        if let after = Step(rawValue: step.rawValue + 1) { step = after }
    }

    func back() {
        if let before = Step(rawValue: step.rawValue - 1) { step = before }
    }

    /// Clears this step's choices and moves on (Create on the last step).
    func skip() {
        switch step {
        case .title: title = ""; author = ""
        case .pageSize: pageSize = .usLetter; orientation = .portrait
        case .style: stylePresetID = nil
        case .character: characterName = ""; characterDescription = ""
        case .story: importStory = false
        }
        next()
    }

    /// What the choices so far add up to. A blank character (no name, no description) is none.
    var spec: NewBookSpec {
        let name = characterName.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = characterDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let character = (name.isEmpty && text.isEmpty) ? nil : NewBookSpec.MainCharacter(name: name, description: text)
        // Letter portrait is the book's default, so it's sent as "no choice".
        let isDefaultSize = pageSize == .usLetter && orientation == .portrait
        return NewBookSpec(title: title, author: author, pageSize: isDefaultSize ? nil : pageSize,
                           orientation: isDefaultSize ? nil : (orientationApplies ? orientation : .portrait),
                           stylePresetID: stylePresetID, mainCharacter: character, importStoryAfter: importStory)
    }
}

/// A preset's sample picture, or a neutral placeholder when it has none.
struct PresetSampleImage: View {
    let preset: StylePreset?
    var size: CGFloat = 64
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(preset.map { Crayon.color(forKey: $0.id) } ?? Crayon.inkSoft.opacity(0.35))
                    .overlay {
                        Image(systemName: "paintpalette.fill")
                            .font(.system(size: size * 0.36, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: Crayon.smallCornerRadius, style: .continuous))
        .accessibilityHidden(true)
        .task(id: preset?.sampleImage) {
            // Read the file off the main actor (#3g).
            let url = preset?.sampleImageURL
            let data = await Task.detached { url.flatMap { try? Data(contentsOf: $0) } }.value
            image = data.flatMap { NSImage(data: $0) }
        }
    }
}

/// Replaces the title-only sheet: title and author, page size, style preset, an optional main
/// character, then an offer to import story text. Back / Skip / Next / Create on every step.
struct NewBookWizard: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var model: NewBookWizardModel
    @State private var error: String?
    @State private var creating = false
    let onCreated: (BookID) -> Void

    init(fromStory: Bool = false, onCreated: @escaping (BookID) -> Void) {
        _model = State(initialValue: NewBookWizardModel(importStory: fromStory))
        self.onCreated = onCreated
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                CrayonBlobIcon(systemImage: stepSymbol, color: stepColor, size: 40)
                Text(heading)
                    .font(Crayon.font(.title2, weight: .heavy))
                    .foregroundStyle(Crayon.ink)
                    .accessibilityAddTraits(.isHeader)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding([.horizontal, .top], 20)
            // A fixed height that fits the tallest step (Style), so the sheet doesn't resize between
            // steps. 290 rather than 320: the footer's step indicator row takes the other 30.
            content.padding(20).frame(maxWidth: .infinity, minHeight: 290, maxHeight: 290, alignment: .topLeading)
            if let error {
                CrayonInlineMessage(error, kind: .error, textStyle: .callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            }
            VStack(spacing: 10) {
                // The indicator gets its own centred line above the buttons, so no button set
                // (Back / Skip / Continue or Create) can reach it.
                VStack(spacing: 4) {
                    StepDots(current: model.step.rawValue, count: NewBookWizardModel.Step.allCases.count)
                    Text("Step \(model.step.rawValue + 1) of \(NewBookWizardModel.Step.allCases.count)")
                        .font(Crayon.font(.caption, weight: .semibold)).foregroundStyle(Crayon.inkSoft)
                }
                .frame(maxWidth: .infinity)
                HStack {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(creating)
                    if creating { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Back") { model.back() }.disabled(model.isFirst || creating)
                    Button("Skip") { skip() }.disabled(creating)
                    if model.isLast {
                        Button("Create") { create() }.keyboardShortcut(.defaultAction).disabled(creating)
                            .buttonStyle(.crayon(Crayon.grass))
                    } else {
                        Button("Continue") { model.next() }.keyboardShortcut(.defaultAction)
                            .buttonStyle(.crayon)
                    }
                }
            }
            .padding(12)
            .background(Crayon.paperDeep)
        }
        .frame(width: 460)
        .crayonPaper()
    }

    /// Each step gets its own crayon and picture.
    private var stepColor: Color { Crayon.color(for: model.step.rawValue) }

    private var stepSymbol: String {
        switch model.step {
        case .title: "character.book.closed.fill"
        case .pageSize: "rectangle.portrait.fill"
        case .style: "paintpalette.fill"
        case .character: "face.smiling.inverse"
        case .story: "text.book.closed.fill"
        }
    }

    private var heading: String {
        switch model.step {
        case .title: "Title and author"
        case .pageSize: "Page size"
        case .style: "Style"
        case .character: "Main character"
        case .story: "Story text"
        }
    }

    private func skip() {
        if model.isLast { model.skip(); create() } else { model.skip() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.step {
        case .title:
            VStack(alignment: .leading, spacing: 12) {
                fieldRow("Title") { TextField("Title", text: $model.title, prompt: Text("Untitled")) }
                fieldRow("Author") { TextField("Author", text: $model.author) }
            }
        case .pageSize:
            VStack(alignment: .leading, spacing: 12) {
                fieldRow("Size") {
                    Picker("Size", selection: $model.pageSize) {
                        ForEach(NewBookWizardModel.pageSizes, id: \.self) { Text($0.displayName).tag($0) }
                    }
                }
                if model.orientationApplies {
                    fieldRow("Orientation") {
                        Picker("Orientation", selection: $model.orientation) {
                            Text("Portrait").tag(Orientation.portrait)
                            Text("Landscape").tag(Orientation.landscape)
                        }
                        .pickerStyle(.segmented)
                    }
                }
                Text("You can change this later in the Style tab.").font(.caption).foregroundStyle(Crayon.inkSoft)
            }
        case .style:
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    styleRow(nil)
                    ForEach(model.presets) { styleRow($0) }
                }
                // Room for the cards' rings and shadows.
                .padding(.horizontal, 4)
                .padding(.vertical, 6)
            }
        case .character:
            VStack(alignment: .leading, spacing: 12) {
                fieldRow("Name") { TextField("Name", text: $model.characterName) }
                fieldRow("Description") {
                    TextField("Description", text: $model.characterDescription, axis: .vertical).lineLimit(3...6)
                }
                Text("Becomes a character in the Assets tab. Leave blank to add characters later.")
                    .font(.caption).foregroundStyle(Crayon.inkSoft)
            }
        case .story:
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Import story text after creating the book", isOn: $model.importStory)
                Text("The book opens with the Import Story Text sheet, so you can paste your text and split it into pages.")
                    .font(.caption).foregroundStyle(Crayon.inkSoft)
            }
        }
    }

    /// A label in a fixed-width column beside its field, so every step's fields start at the same edge.
    private func fieldRow<Field: View>(_ label: String, @ViewBuilder _ field: () -> Field) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(Crayon.font(.body, weight: .semibold)).foregroundStyle(Crayon.ink)
                .frame(width: 96, alignment: .trailing)
            field().labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func styleRow(_ preset: StylePreset?) -> some View {
        let selected = model.stylePresetID == preset?.id
        return Button {
            model.stylePresetID = preset?.id
        } label: {
            HStack(spacing: 10) {
                PresetSampleImage(preset: preset)
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset?.name ?? "No preset")
                        .font(Crayon.font(.body, weight: .bold))
                        .foregroundStyle(Crayon.ink)
                    if let preset {
                        Text(preset.visualDescription).font(.caption).foregroundStyle(Crayon.inkSoft).lineLimit(2)
                    }
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(Crayon.tomato)
                }
            }
            .padding(8)
            .crayonCard(selected: selected, cornerRadius: Crayon.mediumCornerRadius)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .crayonHover(tilt: 0, scale: 1.01)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func create() {
        creating = true
        let spec = model.spec
        Task {
            defer { creating = false }
            do {
                let entry = try await app.createBook(spec: spec)
                dismiss()
                onCreated(entry.id)
            } catch {
                self.error = "Couldn't create the book. \(StoreErrorText.message(for: error))"
            }
        }
    }
}

/// Progress through the wizard's (or setup's) steps: one little crayon stroke per step,
/// coloured up to the current one.
struct StepDots: View {
    let current: Int
    let count: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index <= current ? Crayon.color(for: index) : Crayon.ink.opacity(0.12))
                    .frame(width: index == current ? 18 : 8, height: 6)
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.7), value: current)
        .accessibilityHidden(true)
    }
}
