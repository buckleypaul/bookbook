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

/// The Align and Distribute commands for the selected boxes, shared by the toolbar's Align menu
/// (as sections) and the inspector's multi-selection form (as submenus). Distributing needs
/// three or more boxes.
struct ArrangeMenuItems: View {
    enum Grouping { case sections, submenus }

    let model: TemplateEditorModel
    /// The number of selected boxes.
    let count: Int
    let grouping: Grouping

    var body: some View {
        group("Align") {
            ForEach(AlignOperation.allCases, id: \.self) { op in
                Button(op.title) { model.align(op) }
            }
        }
        group("Distribute") {
            Button("Horizontally") { model.distribute(.horizontal) }.disabled(count < 3)
            Button("Vertically") { model.distribute(.vertical) }.disabled(count < 3)
        }
    }

    @ViewBuilder
    private func group(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        switch grouping {
        case .sections: Section(title) { content() }
        case .submenus: Menu(title) { content() }
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
                ArrangeMenuItems(model: model, count: count, grouping: .sections)
            } label: { Label("Align", systemImage: "align.horizontal.left") }
                .disabled(count == 0)
                .help("Align (one box aligns to its page's safe area) and distribute (three or more)")
            let orderMatters = model.layerOrderHasVisibleEffect
            ControlGroup {
                Button { model.moveSelection(.toFront) } label: { Label("Bring to Front", systemImage: "square.3.layers.3d.top.filled") }
                Button { model.moveSelection(.forward) } label: { Label("Bring Forward", systemImage: "square.2.layers.3d.top.filled") }
                Button { model.moveSelection(.backward) } label: { Label("Send Backward", systemImage: "square.2.layers.3d.bottom.filled") }
                Button { model.moveSelection(.toBack) } label: { Label("Send to Back", systemImage: "square.3.layers.3d.bottom.filled") }
            }
            .disabled(count == 0 || !orderMatters)
            .help(orderMatters ? "Change the layer order of the selected boxes"
                  : "Layer order only matters between boxes of the same kind: text always draws above images")
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
