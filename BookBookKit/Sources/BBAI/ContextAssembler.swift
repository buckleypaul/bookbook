import BBAICore
import BBModel
import Foundation

/// Builds the provider-neutral request from a book snapshot (A §7.3). Pure; snapshot-tested.
public enum ContextAssembler {
    /// Returns nil if the target page, box or session no longer exists.
    public static func assemble(intent: GenerationIntent, target: GenerationTarget, content: BookContent,
                                model: CatalogModel) -> (ImageRequest, AssemblyReport)? {
        guard case let .pageBox(pageID, boxID) = target,
              let page = content.pages[pageID],
              let template = content.template(for: page),
              let box = template.box(boxID), box.content == .image,
              let slot = page.images[boxID],
              content.sessions[slot.sessionID] != nil
        else { return nil }

        let style = content.style
        let storyText = page.storyText(in: template)
        let includeStory = intent.includeStoryText && !storyText.isEmpty
        let aspect = content.boxAspect(box)

        let values: [(key: String, placeholders: [String: String], required: Bool)] = [
            ("role", [:], true),
            ("style", ["style": style.visualDescription.trimmed], !style.visualDescription.trimmed.isEmpty),
            ("avoid", ["avoid": style.negativeGuidance.trimmed], !style.negativeGuidance.trimmed.isEmpty),
            ("composition", ["aspect": describeAspect(aspect), "calm": calmGuidance(box: box, template: template)], true),
            ("story", ["story": storyText], includeStory),
            ("request", ["request": intent.messageText.trimmed], !intent.messageText.trimmed.isEmpty),
        ]
        let sections = values.compactMap { entry -> ComposedPrompt.Section? in
            guard entry.required, let template = PromptTemplates.text(for: entry.key) else { return nil }
            return .init(key: entry.key, text: PromptTemplates.render(template, entry.placeholders))
        }

        let prompt = ComposedPrompt(sections: sections)
        let request = ImageRequest(model: model, quality: intent.quality, output: OutputShape(boxAspect: aspect),
                                   instruction: prompt)
        let report = AssemblyReport(promptText: prompt.rendered, storyTextIncluded: includeStory,
                                    styleRevision: style.visualRevision,
                                    estimatedInputBytes: prompt.rendered.utf8.count)
        return (request, report)
    }

    // MARK: Composition wording

    private static let commonRatios: [(label: String, value: Double)] = [
        ("1:1", 1), ("5:4", 1.25), ("4:3", 4.0 / 3), ("3:2", 1.5), ("16:9", 16.0 / 9), ("2:1", 2), ("3:1", 3),
        ("4:5", 0.8), ("3:4", 0.75), ("2:3", 2.0 / 3), ("9:16", 9.0 / 16), ("1:2", 0.5), ("1:3", 1.0 / 3),
    ]

    /// e.g. "landscape, about 3:2".
    static func describeAspect(_ aspect: Double) -> String {
        guard aspect.isFinite, aspect > 0 else { return "square, about 1:1" }
        let orientation = aspect > 1.05 ? "landscape" : aspect < 0.95 ? "portrait" : "square"
        let nearest = commonRatios.min { abs(log(aspect / $0.value)) < abs(log(aspect / $1.value)) }
        return "\(orientation), about \(nearest?.label ?? "1:1")"
    }

    /// Leading-space sentence naming the part of the image that text boxes cover, or "".
    static func calmGuidance(box: Box, template: Template) -> String {
        let frame = box.frame
        guard frame.width > 0, frame.height > 0 else { return "" }
        var phrases: [String] = []
        for textBox in template.textBoxes {
            guard let overlap = frame.intersection(textBox.frame) else { continue }
            let local = NormalizedRect(x: (overlap.x - frame.x) / frame.width, y: (overlap.y - frame.y) / frame.height,
                                       width: overlap.width / frame.width, height: overlap.height / frame.height)
            guard local.width * local.height >= 0.02 else { continue }
            phrases.append(describeRegion(local))
        }
        guard !phrases.isEmpty else { return "" }
        var seen = Set<String>()
        let unique = phrases.filter { seen.insert($0).inserted }
        return " Leave " + unique.joined(separator: " and ") + " calm and low-detail for text."
    }

    private static func describeRegion(_ r: NormalizedRect) -> String {
        let wide = r.width >= 0.7, tall = r.height >= 0.7
        if wide && tall { return "the whole image" }
        let midX = r.x + r.width / 2, midY = r.y + r.height / 2
        let horizontal = midX < 0.4 ? "left" : midX > 0.6 ? "right" : "center"
        let vertical = midY < 0.4 ? "top" : midY > 0.6 ? "bottom" : "middle"
        if wide {
            return "the \(vertical) \(fraction(r.height))"
        }
        if tall {
            return "the \(horizontal) \(fraction(r.width))"
        }
        return "the \(vertical) \(horizontal) area"
    }

    private static func fraction(_ f: Double) -> String {
        let options: [(String, Double)] = [("quarter", 0.25), ("third", 1.0 / 3), ("half", 0.5), ("two thirds", 2.0 / 3),
                                           ("three quarters", 0.75)]
        return options.min { abs($0.1 - f) < abs($1.1 - f) }?.0 ?? "half"
    }
}

extension Page {
    /// The page's text boxes' plain text, in template order, joined by a blank line.
    fileprivate func storyText(in template: Template) -> String {
        template.textBoxes
            .compactMap { text[$0.id] }
            .map(\.plainText)
            .map { $0.trimmed }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }
}

extension String {
    fileprivate var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// Versioned prompt text files in `Resources/Prompts/<version>/<key>.txt` with `{{name}}` substitution.
enum PromptTemplates {
    static let version = "image-v1"

    static func text(for key: String) -> String? {
        guard let base = Bundle.module.resourceURL?.appendingPathComponent("Prompts/\(version)/\(key).txt"),
              let text = try? String(contentsOf: base, encoding: .utf8) else { return nil }
        return text.trimmingCharacters(in: .newlines)
    }

    static func render(_ template: String, _ values: [String: String]) -> String {
        var out = template
        for (name, value) in values { out = out.replacingOccurrences(of: "{{\(name)}}", with: value) }
        return out
    }
}
