import BBLayout
import BBModel
import SwiftUI

/// A number field that commits on Return or when it loses focus.
struct CommitField: View {
    let title: String
    let value: Double
    var fractionDigits: Int = 1
    let commit: (Double) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(title, text: $text)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .focused($focused)
            .onAppear { text = format(value) }
            .onChange(of: value) { _, new in text = format(new) }  // also while focused: Return keeps focus
            .onSubmit(finish)
            .onKeyPress(.return) { finish(); return .handled }
            .onChange(of: focused) { _, now in if !now { finish() } }
    }

    private func finish() {
        if let parsed = Double(text.trimmingCharacters(in: .whitespaces)), parsed.isFinite,
           abs(parsed - value) > 1e-9 {
            commit(parsed)
        }
        text = format(value)
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

    var body: some View {
        let boxes = model.selectedBoxes
        Group {
            if model.template == nil {
                ContentUnavailableView("No Layout Open", systemImage: "rectangle.3.group")
            } else if boxes.isEmpty {
                ContentUnavailableView("No Box Selected", systemImage: "square.dashed",
                                       description: Text("Click a box on the canvas, or add one from the toolbar."))
            } else if boxes.count > 1 {
                multi(count: boxes.count)
            } else if let box = boxes.first, let geometry = model.geometry {
                single(box, geometry: geometry).id(box.id)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func multi(count: Int) -> some View {
        Form {
            Section("\(count) Boxes Selected") {
                Menu("Align") {
                    ForEach(AlignOperation.allCases, id: \.self) { op in Button(op.title) { model.align(op) } }
                }
                Menu("Distribute") {
                    Button("Horizontally") { model.distribute(.horizontal) }.disabled(count < 3)
                    Button("Vertically") { model.distribute(.vertical) }.disabled(count < 3)
                }
                HStack {
                    Button("Front") { model.moveSelection(.toFront) }
                    Button("Forward") { model.moveSelection(.forward) }
                    Button("Backward") { model.moveSelection(.backward) }
                    Button("Back") { model.moveSelection(.toBack) }
                }
                .controlSize(.small)
            }
        }
        .formStyle(.grouped)
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
            Section("Frame (pt)") {
                LabeledContent("X") { CommitField(title: "X", value: rect.minX) { v in setRect("Move Box") { $0.origin.x = v } } }
                LabeledContent("Y") { CommitField(title: "Y", value: rect.minY) { v in setRect("Move Box") { $0.origin.y = v } } }
                LabeledContent("Width") {
                    CommitField(title: "Width", value: rect.width) { v in setRect("Resize Box") { $0.size.width = max(1, v) } }
                }
                LabeledContent("Height") {
                    CommitField(title: "Height", value: rect.height) { v in setRect("Resize Box") { $0.size.height = max(1, v) } }
                }
            }
            Section("Shape") {
                slider("Rotation", value: box.rotationDegrees, range: -180...180, unit: "°", action: "Rotate Box") { b, v in
                    b.rotationDegrees = v
                } edit: { name, body in edit(name, body) }
                slider("Corner Radius", value: box.cornerRadius, range: 0...120, unit: "pt", action: "Change Corner Radius") { b, v in
                    b.cornerRadius = max(0, v)
                } edit: { name, body in edit(name, body) }
            }
            Section("Full Bleed") {
                let all = box.bleedEdges == .all
                Toggle("All", isOn: Binding(get: { all }, set: { on in
                    edit("Change Full Bleed") { $0.bleedEdges = on ? .all : [] }
                }))
                HStack {
                    edgeToggle("Top", .top, box, edit)
                    edgeToggle("Leading", .leading, box, edit)
                    edgeToggle("Bottom", .bottom, box, edit)
                    edgeToggle("Trailing", .trailing, box, edit)
                }
                .toggleStyle(.checkbox)
                .controlSize(.small)
            }
            if case let .text(style) = box.content {
                textSection(style, edit: edit)
            }
        }
        .formStyle(.grouped)
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
                Text(title).lineLimit(1).fixedSize()
                Spacer()
                CommitField(title: title, value: value) { v in edit(action) { apply(&$0, v) } }
                    .frame(width: 64)
                Text(unit).foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { min(max(value, range.lowerBound), range.upperBound) },
                                  set: { v in edit(action) { apply(&$0, v) } }),
                   in: range) { editing in
                if editing { model.beginInteraction() } else { model.endInteraction(actionName: action) }
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
        return Section("Text") {
            Toggle("Override Font Size", isOn: Binding(get: { style.fontSize != nil }, set: { on in
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
                Text("Style").tag(Align?.none)
                Text("Leading").tag(Align?.some(.leading))
                Text("Centre").tag(Align?.some(.center))
                Text("Trailing").tag(Align?.some(.trailing))
                Text("Justified").tag(Align?.some(.justified))
            }
            colourRow("Text Colour", color: style.color, noneLabel: "Style", initial: RGBA(red: 0, green: 0, blue: 0)) { c in
                setStyle("Change Text Colour", continuous: true) { $0.color = c }
            }
            colourRow("Background Panel", color: style.background, noneLabel: "None", initial: RGBA(red: 1, green: 0.96, blue: 0.86)) { c in
                setStyle("Change Background", continuous: true) { $0.background = c }
            }
            Stepper(value: Binding(get: { style.padding }, set: { v in
                setStyle("Change Padding", continuous: true) { $0.padding = max(0, v) }
            }), in: 0...100, step: 1) {
                Text("Padding \(style.padding.formatted(.number.precision(.fractionLength(0...1)))) pt")
            }
        }
    }

    /// An optional colour: a checkbox to turn the override on, and a colour well.
    private func colourRow(_ title: String, color: RGBA?, noneLabel: String, initial: RGBA,
                           set: @escaping (RGBA?) -> Void) -> some View {
        HStack {
            Toggle(title, isOn: Binding(get: { color != nil }, set: { on in
                set(on ? initial : nil)
            }))
            Spacer()
            if let color {
                ColorPicker(title, selection: Binding(get: { color.swiftUIColor },
                                                      set: { set(RGBA(color: $0)) }), supportsOpacity: true)
                    .labelsHidden()
            } else {
                Text(noneLabel).foregroundStyle(.secondary)
            }
        }
    }
}
