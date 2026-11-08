import BBLayout
import BBModel
import SwiftUI

/// The Layouts tab's detail area: the editor toolbar above the template canvas.
struct LayoutsDetail: View {
    let document: BookDocument
    let model: TemplateEditorModel
    let images: ImageCache

    var body: some View {
        VStack(spacing: 0) {
            if model.template != nil {
                LayoutsToolbar(model: model)
                    .disabled(!document.isEditable)
                Divider()
                TemplateCanvas(model: model, imageSource: images)
                    .allowsHitTesting(document.isEditable)
            } else {
                ContentUnavailableView("No Layout Selected", systemImage: "rectangle.3.group",
                                       description: Text("Choose a layout, or add one with New Layout."))
            }
        }
    }
}

struct LayoutsToolbar: View {
    @Bindable var model: TemplateEditorModel

    var body: some View {
        let count = model.selectedBoxes.count
        HStack(spacing: 12) {
            ControlGroup {
                Button { model.addBox(.image) } label: { Label("Image Box", systemImage: "photo.badge.plus") }
                    .help("Add an image box")
                Button { model.addBox(.text(TextBoxStyle())) } label: { Label("Text Box", systemImage: "character.textbox") }
                    .help("Add a text box")
            }
            Menu {
                Section("Align") {
                    ForEach(AlignOperation.allCases, id: \.self) { op in
                        Button(op.title) { model.align(op) }
                    }
                }
                Section("Distribute") {
                    Button("Horizontally") { model.distribute(.horizontal) }.disabled(count < 3)
                    Button("Vertically") { model.distribute(.vertical) }.disabled(count < 3)
                }
            } label: { Label("Align", systemImage: "align.horizontal.left") }
                .disabled(count == 0)
                .help("Align (one box aligns to its page's safe area) and distribute (three or more)")
            ControlGroup {
                Button { model.moveSelection(.toFront) } label: { Label("Bring to Front", systemImage: "square.3.layers.3d.top.filled") }
                Button { model.moveSelection(.forward) } label: { Label("Bring Forward", systemImage: "square.2.layers.3d.top.filled") }
                Button { model.moveSelection(.backward) } label: { Label("Send Backward", systemImage: "square.2.layers.3d.bottom.filled") }
                Button { model.moveSelection(.toBack) } label: { Label("Send to Back", systemImage: "square.3.layers.3d.bottom.filled") }
            }
            .disabled(count == 0)
            Button(role: .destructive) { model.deleteSelection() } label: { Label("Delete Box", systemImage: "trash") }
                .disabled(count == 0)
                .help("Delete the selected boxes")
            Spacer()
            Toggle(isOn: $model.showSampleContent) { Label("Sample Content", systemImage: "text.below.photo") }
                .toggleStyle(.button)
                .help("Show sample text and placeholder art in empty boxes")
            Toggle(isOn: $model.snappingEnabled) { Label("Snapping", systemImage: "dot.squareshape.split.2x2") }
                .toggleStyle(.button)
                .help("Snap to margins, guides and other boxes (hold ⌘ to snap off temporarily)")
        }
        .labelStyle(.iconOnly)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

extension AlignOperation {
    var title: String {
        switch self {
        case .left: "Left"
        case .horizontalCenter: "Centre Horizontally"
        case .right: "Right"
        case .top: "Top"
        case .verticalCenter: "Centre Vertically"
        case .bottom: "Bottom"
        }
    }
}
