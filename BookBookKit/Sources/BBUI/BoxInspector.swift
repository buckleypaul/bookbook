import BBLayout
import AppKit
import BBModel
import SwiftUI

/// A number field that commits on Return or when it loses focus.
struct CommitField: View {
    let title: String
    let value: Double
    var fractionDigits: Int = 1
    let commit: (Double) -> Void
    @State private var text = ""
    /// What the field last showed of `value`; `text` differs from it once the user types.
    @State private var shown = ""
    @FocusState private var focused: Bool

    var body: some View {
        // The row shows the title (LabeledContent or the slider's label): in a grouped Form a
        // titled TextField would draw it again, squeezed into the field's narrow width (the
        // duplicated Frame labels and the mid-word wrapping). Hidden, it stays the accessibility label.
        TextField(title, text: $text)
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .focused($focused)
            .onAppear { show(value) }
            // A canvas drag or an undo changes `value` while the field may be focused: follow
            // it, unless the user has half-typed a number (it's kept until commit). After this
            // field's own commit `text == shown` again (Return keeps focus), so it follows.
            .onChange(of: value) { _, new in if !focused || text == shown { show(new) } }
            .onSubmit(submit)
            .onKeyPress(.return) { submit(); return .handled }
            .onChange(of: focused) { _, now in if !now { finish() } }
    }

    private func show(_ v: Double) {
        text = format(v)
        shown = text
    }

    /// Return: commit, then end editing so the window's undo manager (not the field editor's
    /// empty one) drives Edit > Undo.
    private func submit() {
        finish()
        focused = false
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    private func finish() {
        // Commit only what the user typed: an untouched field never writes its (maybe stale) text.
        if text != shown, let parsed = Double(text.trimmingCharacters(in: .whitespaces)), parsed.isFinite,
           abs(parsed - value) > 1e-9 {
            commit(parsed)
            // `value` hasn't arrived yet: show what was committed; `onChange(of: value)` then
            // follows any clamping by the model.
            show(parsed)
        } else {
            show(value)
        }
    }

    private func format(_ v: Double) -> String {
        v.formatted(.number.precision(.fractionLength(0...fractionDigits)).grouping(.never))
    }
}

/// The trailing inspector of the Layouts tab: the selected box's frame, rotation, corner radius,
/// bleed edges and text style. Every edit is a `model.update` (one undo step) or, for sliders,
/// colour wells and steppers, one interaction.
private typealias Align = BBModel.TextAlignment

struct BoxInspector: View {
    let model: TemplateEditorModel
    /// The open slider drag's interaction token. An undo mid-drag ends the interaction; the
    /// slider then edits nothing until it is released.
    @State private var sliderInteraction: Int?

    var body: some View {
        let boxes = model.selectedBoxes
        Group {
            if model.template == nil {
                CrayonEmptyState("No Layout Selected", systemImage: "rectangle.3.group", color: Crayon.sky)
            } else if boxes.isEmpty {
                CrayonEmptyState("No Box Selected", systemImage: "square.dashed", color: Crayon.sky,
                                 message: "Click a box on the canvas, or add one from the toolbar.")
            } else if boxes.count > 1 {
                multi(count: boxes.count)
            } else if let box = boxes.first, let geometry = model.geometry {
                single(box, geometry: geometry).id(box.id)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func multi(count: Int) -> some View {
        let orderMatters = model.layerOrderHasVisibleEffect
        return Form {
            Section {
                ArrangeMenuItems(model: model, count: count, grouping: .submenus)
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                    GridRow {
                        Button("Bring to Front") { model.moveSelection(.toFront) }
                        Button("Bring Forward") { model.moveSelection(.forward) }
                    }
                    GridRow {
                        Button("Send Backward") { model.moveSelection(.backward) }
                        Button("Send to Back") { model.moveSelection(.toBack) }
                    }
                }
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .disabled(!orderMatters)
                .help(orderMatters ? "Change the layer order of the selected boxes"
                      : "Layer order only matters between boxes of the same kind: text always draws above images")
            } header: {
                CrayonHeader("\(count) Boxes Selected", color: Crayon.sky)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .crayonPaper()
    }

    private func single(_ box: Box, geometry: PageGeometry) -> some View {
        let id = box.id
        let rect = geometry.trimRect(for: box.frame)
        func edit(_ name: String, continuous: Bool = false, _ change: @escaping (inout Box) -> Void) {
            let body: (inout Template) -> Void = { t in
                if let i = t.boxes.firstIndex(where: { $0.id == id }) { change(&t.boxes[i]) }
            }
            if continuous { model.updateContinuously(actionName: name, body) } else { model.update(actionName: name, body) }
        }
        func setRect(_ name: String, _ change: @escaping (inout CGRect) -> Void) {
            edit(name) { b in
                var r = geometry.trimRect(for: b.frame)
                change(&r)
                b.frame = geometry.normalizedFrame(for: r)
            }
        }
        return Form {
            Section {
                LabeledContent("X") { CommitField(title: "X", value: rect.minX) { v in setRect("Move Box") { $0.origin.x = v } } }
                LabeledContent("Y") { CommitField(title: "Y", value: rect.minY) { v in setRect("Move Box") { $0.origin.y = v } } }
                LabeledContent("Width") {
                    CommitField(title: "Width", value: rect.width) { v in setRect("Resize Box") { $0.size.width = max(1, v) } }
                }
                LabeledContent("Height") {
                    CommitField(title: "Height", value: rect.height) { v in setRect("Resize Box") { $0.size.height = max(1, v) } }
                }
            } header: {
                CrayonHeader("Frame (pt)", color: Crayon.sky)
            }
            Section {
                slider("Rotation", value: box.rotationDegrees, range: -180...180, unit: "deg", action: "Rotate Box") { b, v in
                    b.rotationDegrees = v
                } edit: { name, body in edit(name, body) }
                slider("Corner radius", value: box.cornerRadius, range: 0...120, unit: "pt", action: "Change Corner Radius") { b, v in
                    b.cornerRadius = max(0, v)
                } edit: { name, body in edit(name, body) }
            } header: {
                CrayonHeader("Shape", color: Crayon.grape)
            }
            Section {
                let all = box.bleedEdges == .all
                Toggle("All", isOn: Binding(get: { all }, set: { on in
                    edit("Change Full Bleed") { $0.bleedEdges = on ? .all : [] }
                }))
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow {
                        edgeToggle("Top", .top, box, edit)
                        edgeToggle("Left", .leading, box, edit)
                    }
                    GridRow {
                        edgeToggle("Bottom", .bottom, box, edit)
                        edgeToggle("Right", .trailing, box, edit)
                    }
                }
                .toggleStyle(.checkbox)
                .controlSize(.small)
            } header: {
                CrayonHeader("Full bleed", color: Crayon.grass)
            }
            if case let .text(style) = box.content {
                textSection(style, edit: edit)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .crayonPaper()
    }

    private func edgeToggle(_ title: String, _ edge: EdgeSet, _ box: Box,
                            _ edit: @escaping (String, Bool, @escaping (inout Box) -> Void) -> Void) -> some View {
        Toggle(title, isOn: Binding(get: { box.bleedEdges.contains(edge) }, set: { on in
            edit("Change Full Bleed", false) { if on { $0.bleedEdges.insert(edge) } else { $0.bleedEdges.remove(edge) } }
        }))
    }

    private func slider(_ title: String, value: Double, range: ClosedRange<Double>, unit: String, action: String,
                        apply: @escaping (inout Box, Double) -> Void,
                        edit: @escaping (String, @escaping (inout Box) -> Void) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).lineLimit(1).fixedSize(horizontal: true, vertical: false).layoutPriority(1)
                Spacer(minLength: 4)
                CommitField(title: title, value: value) { v in edit(action) { apply(&$0, v) } }
                    .frame(minWidth: 44, idealWidth: 64, maxWidth: 64)
                Text(unit).foregroundStyle(Crayon.inkSoft)
                    .frame(width: 24, alignment: .leading)
            }
            Slider(value: Binding(get: { min(max(value, range.lowerBound), range.upperBound) },
                                  set: { v in
                                      if let token = sliderInteraction, !model.isInteractionOpen(token) { return }
                                      edit(action) { apply(&$0, v) }
                                  }),
                   in: range) { editing in
                if editing {
                    sliderInteraction = model.beginInteraction(actionName: action)
                } else {
                    if let token = sliderInteraction {
                        model.endInteraction(token, actionName: action)
                    }
                    sliderInteraction = nil
                }
            }
        }
    }

    private func textSection(_ style: TextBoxStyle,
                             edit: @escaping (String, Bool, @escaping (inout Box) -> Void) -> Void) -> some View {
        func setStyle(_ name: String, continuous: Bool = false, _ change: @escaping (inout TextBoxStyle) -> Void) {
            edit(name, continuous) { b in
                if case var .text(s) = b.content { change(&s); b.content = .text(s) }
            }
        }
        return Section {
            Toggle("Override font size", isOn: Binding(get: { style.fontSize != nil }, set: { on in
                setStyle("Change Font Size") { $0.fontSize = on ? ($0.fontSize ?? 18) : nil }
            }))
            if let size = style.fontSize {
                Stepper(value: Binding(get: { size }, set: { v in setStyle("Change Font Size", continuous: true) { $0.fontSize = v } }),
                        in: 4...200, step: 1) {
                    Text("\(size.formatted(.number.precision(.fractionLength(0...1)))) pt")
                }
            }
            Picker("Alignment", selection: Binding(get: { style.alignment }, set: { a in
                setStyle("Change Alignment") { $0.alignment = a }
            })) {
                Text("Style Default").tag(Align?.none)
                Text("Left").tag(Align?.some(.leading))
                Text("Centre").tag(Align?.some(.center))
                Text("Right").tag(Align?.some(.trailing))
                Text("Justified").tag(Align?.some(.justified))
            }
            colourRow("Text colour", color: style.color, noneLabel: "Style Default", initial: RGBA(red: 0, green: 0, blue: 0)) { c in
                setStyle("Change Text Colour", continuous: true) { $0.color = c }
            }
            colourRow("Background panel", color: style.background, noneLabel: "None", initial: RGBA(red: 1, green: 0.96, blue: 0.86)) { c in
                setStyle("Change Background", continuous: true) { $0.background = c }
            }
            Stepper(value: Binding(get: { style.padding }, set: { v in
                setStyle("Change Padding", continuous: true) { $0.padding = max(0, v) }
            }), in: 0...100, step: 1) {
                Text("Padding \(style.padding.formatted(.number.precision(.fractionLength(0...1)))) pt")
            }
        } header: {
            CrayonHeader("Text", color: Crayon.tomato)
        }
    }

    /// An optional colour: a checkbox to turn the override on, and a colour well.
    private func colourRow(_ title: String, color: RGBA?, noneLabel: String, initial: RGBA,
                           set: @escaping (RGBA?) -> Void) -> some View {
        HStack {
            Text(title)
            Spacer()
            if let color {
                ColorPicker(title, selection: Binding(get: { color.swiftUIColor },
                                                      set: { new in
                    // The well echoes our own colour back after a colour-space round trip:
                    // ignore changes too small to see, so they never become an edit.
                    let rgba = RGBA(color: new)
                    let close = [abs(rgba.red - color.red), abs(rgba.green - color.green),
                                 abs(rgba.blue - color.blue), abs(rgba.alpha - color.alpha)].allSatisfy { $0 < 0.5 / 255 }
                    if !close { set(rgba) }
                }), supportsOpacity: true)
                    .labelsHidden()
            } else {
                Text(noneLabel).foregroundStyle(Crayon.inkSoft)
            }
            Toggle(title, isOn: Binding(get: { color != nil }, set: { on in
                set(on ? initial : nil)
            }))
            .labelsHidden()
        }
    }
}

/// An image box's out-of-date flags with a Mark as OK button (page editor inspector). Shows
/// nothing when the box has no flags.
struct ImageFlagsRow: View {
    let flags: ImageFlags
    let editable: Bool
    let markOK: () -> Void

    var body: some View {
        if !flags.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(FlagText.entries(flags), id: \.title) { entry in
                    Label(entry.title, systemImage: entry.symbol)
                        .foregroundStyle(entry.color)
                        .help(entry.help)
                }
                Button("Mark as OK", action: markOK)
                    .controlSize(.small)
                    .buttonBorderShape(.capsule)
                    .disabled(!editable)
                    .help("Accept this image as it is and clear its flags")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Crayon.paperDeep)
            Divider()
        }
    }
}
