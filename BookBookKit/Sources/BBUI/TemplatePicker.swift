import BBModel
import BBStore
import SwiftUI

/// A grid of templates to choose from (add page, change layout, story import): a box diagram
/// and the name of each. Spreads draw double width.
struct TemplatePicker: View {
    let templates: [Template]
    let trimSize: PointSize
    @Binding var selection: TemplateID?
    /// Double-click (or return) picks a template straight away.
    var onConfirm: ((TemplateID) -> Void)?
    /// The page's layout now (Change Layout), marked "Current" under its name.
    var currentTemplateID: TemplateID?

    private let height: CGFloat = 80

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 14)], spacing: 16) {
                ForEach(templates) { template in
                    cell(template)
                }
            }
            // Room for the cards' shadows and hover lift.
            .padding(12)
        }
    }

    private func cell(_ template: Template) -> some View {
        let aspect = trimSize.height > 0 ? trimSize.width / trimSize.height : 0.75
        let width = height * aspect * (template.kind == .spread ? 2 : 1)
        let selected = selection == template.id
        let isCurrent = currentTemplateID == template.id
        return VStack(spacing: 6) {
            TemplateDiagram(template: template)
                .frame(width: min(width, 200), height: height)
                .shadow(color: Crayon.shadow, radius: 0, x: 0, y: 1.5)
                .padding(8)
                .crayonCard(selected: selected, cornerRadius: Crayon.mediumCornerRadius)
                .crayonHover()
            Text(template.name)
                .font(Crayon.font(.caption, weight: selected ? .bold : .semibold))
                .foregroundStyle(selected ? Crayon.tomato : Crayon.ink)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            if isCurrent {
                CrayonSticker("Current", systemImage: "checkmark", color: Crayon.grass)
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            selection = template.id
            onConfirm?(template.id)
        }
        .simultaneousGesture(TapGesture().onEnded { selection = template.id })
        .accessibilityElement(children: .combine)
        .accessibilityValue(isCurrent ? "Current layout" : "")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { selection = template.id }
    }
}

/// A template's boxes as a diagram: grey image boxes, lined text boxes.
struct TemplateDiagram: View {
    let template: Template

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            for box in template.boxes {
                let rect = CGRect(x: box.frame.x * size.width, y: box.frame.y * size.height,
                                  width: box.frame.width * size.width, height: box.frame.height * size.height)
                // Crayon-tinted boxes on the white page (a diagram, not page art).
                switch box.content {
                case .image:
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(Crayon.sky.opacity(0.4)))
                case .text:
                    ctx.stroke(Path(rect), with: .color(Crayon.grape.opacity(0.5)), lineWidth: 0.5)
                    var y = rect.minY + 3
                    while y < rect.maxY - 2 {
                        ctx.fill(Path(CGRect(x: rect.minX + 2, y: y, width: max(0, rect.width - 4), height: 1)),
                                 with: .color(Crayon.grape.opacity(0.55)))
                        y += 4
                    }
                }
            }
            if template.kind == .spread {
                ctx.fill(Path(CGRect(x: size.width / 2, y: 0, width: 0.5, height: size.height)),
                         with: .color(.black.opacity(0.3)))
            }
            ctx.stroke(Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(0.2)), lineWidth: 1)
        }
        .accessibilityLabel(template.name)
    }
}

/// A sheet that picks a template, for adding a page or changing a page's layout.
struct TemplatePickerSheet: View {
    let title: String
    let confirmTitle: String
    let templates: [Template]
    let trimSize: PointSize
    let initialSelection: TemplateID?
    /// The page's layout now (Change Layout): marked in the grid, and choosing it again is
    /// disabled because it would change nothing.
    var currentTemplateID: TemplateID? = nil
    let onChoose: (TemplateID) -> Void
    @State private var selection: TemplateID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CrayonHeader(title)
            TemplatePicker(templates: templates, trimSize: trimSize, selection: $selection,
                           onConfirm: { if $0 != currentTemplateID { choose($0) } },
                           currentTemplateID: currentTemplateID)
                .frame(minHeight: 260)
                .background(Crayon.paperDeep, in: .rect(cornerRadius: Crayon.cornerRadius, style: .continuous))
            CrayonSheetFooter(confirmTitle, isDisabled: selection == nil || selection == currentTemplateID) {
                if let selection { choose(selection) }
            }
        }
        .crayonSheet(width: 560, height: 420)
        .onAppear { if selection == nil { selection = initialSelection ?? templates.first?.id } }
    }

    /// `onChoose` closes the sheet itself (via `PagesController.dismissSheet(then:)`), so a
    /// split warning can follow.
    private func choose(_ id: TemplateID) {
        onChoose(id)
    }
}

extension Presets {
    /// The bundled templates (read once), or none if they can't be read.
    static let bundledTemplates: [Template] = (try? templates()) ?? []

    /// The book's template `id`, else the bundled preset with that ID.
    static func template(_ id: TemplateID, in content: BookContent) -> Template? {
        content.templates[id] ?? bundledTemplates.first { $0.id == id }
    }
}
