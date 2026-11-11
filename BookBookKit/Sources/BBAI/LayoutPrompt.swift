import BBAICore
import BBModel
import Foundation

// Phase 12. A §7.7.

public enum LayoutPrompt {
    static let set = "layout-v1"

    /// Renders the layout request: the description, the page setup (size, orientation, margins,
    /// bleed, single or spread) and two presets of the same `kind` as few-shot examples.
    public static func request(description: String, kind: TemplateKind, pageSetup: PageSetup,
                               presets: [Template], model: CatalogTextModel) -> LayoutRequest {
        let chosen = examples(kind: kind, from: presets)
        let examplesText = chosen.enumerated().map { index, preset in
            "Example \(index + 1) (\(preset.name)):\n" + json(draft(from: preset, pageSetup: pageSetup))
        }.joined(separator: "\n\n")

        var values = setupValues(kind: kind, pageSetup: pageSetup)
        values["description"] = description.trimmingCharacters(in: .whitespacesAndNewlines)
        values["examples"] = examplesText.isEmpty ? "" : "Examples of the output format:\n\n" + examplesText
        let user = PromptTemplates.render(PromptTemplates.text(for: "user", set: set) ?? "", values)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return LayoutRequest(model: model, system: PromptTemplates.text(for: "system", set: set) ?? "", user: user)
    }

    /// Renders a revision of `current` in the Layouts chat: the current layout as the schema's
    /// JSON (so manual edits are included), the earlier requests of the thread (oldest first),
    /// the new instruction and the page setup. Same system prompt and schema as `request`.
    public static func revisionRequest(instruction: String, history: [String], current: Template,
                                       pageSetup: PageSetup, model: CatalogTextModel) -> LayoutRequest {
        let earlier = history.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var values = setupValues(kind: current.kind, pageSetup: pageSetup)
        values["current"] = json(draft(from: current, pageSetup: pageSetup))
        values["history"] = earlier.isEmpty ? "(none)" : earlier.map { "- \($0)" }.joined(separator: "\n")
        values["instruction"] = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = PromptTemplates.render(PromptTemplates.text(for: "revise", set: set) ?? "", values)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return LayoutRequest(model: model, system: PromptTemplates.text(for: "system", set: set) ?? "", user: user)
    }

    /// The page-setup placeholders shared by both prompts: kind, size, orientation, margins, bleed.
    static func setupValues(kind: TemplateKind, pageSetup: PageSetup) -> [String: String] {
        let area = TemplateNormalizer.layoutArea(kind: kind, pageSetup: pageSetup)
        let lines = TemplateNormalizer.snapLines(kind: kind, pageSetup: pageSetup)
        func num(_ v: Double) -> String {
            let s = String(format: "%.2f", v)
            return s.contains(".") ? String(s.reversed().drop { $0 == "0" }.drop { $0 == "." }.reversed()) : s
        }
        func inches(_ points: Double) -> String { num(points / 72) }
        let page = pageSetup.trimSize
        let size = "\(num(page.width)) x \(num(page.height)) pt (\(inches(page.width)) x \(inches(page.height)) in)"
            + (kind == .spread ? " per page; the layout area is two pages wide: \(num(area.width)) x \(num(area.height)) pt" : "")
        let m = pageSetup.margins
        let xs = lines.x.filter { $0 > 0 && $0 < 1 }.map { String(format: "%.4f", $0) }.joined(separator: ", ")
        let ys = lines.y.filter { $0 > 0 && $0 < 1 }.map { String(format: "%.4f", $0) }.joined(separator: ", ")
        let margins = "top \(num(m.top)) pt, leading \(num(m.leading)) pt, bottom \(num(m.bottom)) pt, trailing \(num(m.trailing)) pt"
            + " (margin lines at x = \(xs.isEmpty ? "none" : xs); y = \(ys.isEmpty ? "none" : ys))"
        let bleed = pageSetup.bleedEnabled
            ? "on (\(num(pageSetup.bleedAmount)) pt); images that touch a page edge run into the bleed"
            : "off"
        return [
            "kind": kind == .spread ? "spread (two facing pages)" : "single page",
            "size": size,
            "orientation": pageSetup.orientation.rawValue,
            "margins": margins,
            "bleed": bleed,
        ]
    }

    /// Two presets of the same `kind`, preferring ordinary layouts (no front/back-matter role).
    static func examples(kind: TemplateKind, from presets: [Template]) -> [Template] {
        let matching = presets.filter { $0.kind == kind }
        let plain = matching.filter { $0.pageRole == nil }
        let rest = matching.filter { $0.pageRole != nil }
        return Array((plain + rest).prefix(2))
    }

    /// A preset as a few-shot `TemplateDraft` (the inverse of `TemplateNormalizer`).
    public static func draft(from template: Template, pageSetup: PageSetup) -> TemplateDraft {
        let boxes = template.boxes.map { box -> DraftBox in
            let radius = box.cornerRadius > 0 ? box.cornerRadius : nil
            switch box.content {
            case .image:
                return DraftBox(kind: .image, x: box.frame.x, y: box.frame.y, width: box.frame.width,
                                height: box.frame.height, cornerRadius: radius)
            case let .text(style):
                return DraftBox(kind: .text, x: box.frame.x, y: box.frame.y, width: box.frame.width,
                                height: box.frame.height,
                                textAlignment: style.alignment.flatMap { DraftBox.Alignment(rawValue: $0.rawValue) },
                                cornerRadius: radius, backgroundColor: style.background.map(TemplateNormalizer.hex))
            }
        }
        return TemplateDraft(name: template.name, boxes: boxes)
    }

    /// The draft as the schema's JSON (every property present, `null` for nil), keys sorted.
    static func json(_ draft: TemplateDraft) -> String {
        func nullable(_ value: Any?) -> Any { value ?? NSNull() }
        let boxes: [[String: Any]] = draft.boxes.map { box in
            ["kind": box.kind.rawValue, "x": box.x, "y": box.y, "width": box.width, "height": box.height,
             "textAlignment": nullable(box.textAlignment?.rawValue), "cornerRadius": nullable(box.cornerRadius),
             "backgroundColor": nullable(box.backgroundColor)]
        }
        let object: [String: Any] = ["name": draft.name, "boxes": boxes]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}
