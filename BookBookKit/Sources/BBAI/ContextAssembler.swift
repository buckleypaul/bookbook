import BBAICore
import BBModel
import Foundation
import ImageIO

/// An image the assembler needs bytes for, in send order (A §7.3, §7.9).
public struct PlannedImage: Hashable, Sendable {
    public var ref: ImageRef
    /// `base`, `style` or `reference`.
    public var role: String
    public var label: String
    /// Known for versions; nil for style references until the bytes are read.
    public var pixelSize: PixelSize?
}

/// Why assembly could not produce a request.
public enum AssemblyError: Error, Hashable, Sendable {
    /// The page, box, template or session is gone.
    case targetGone
    /// The version to refine no longer exists.
    case baseVersionGone
    /// The base image's bytes are missing from the image store.
    case baseImageMissing
    /// The base image is larger than the model accepts.
    case baseImageTooLarge

    /// What a failed queue item reports.
    public var providerError: ProviderError {
        switch self {
        case .targetGone: .unknown(nil)
        case .baseVersionGone, .baseImageMissing, .baseImageTooLarge: .invalidRequest(param: "image", nil)
        }
    }
}

/// Builds the provider-neutral request from a book snapshot (A §7.3). Pure; snapshot-tested.
/// Two steps so the queue can load bytes in between: `plan` lists the images needed, `assemble`
/// takes their bytes.
public enum ContextAssembler {
    struct Resolved {
        var page: Page
        var template: Template
        var box: Box
        var session: Session
    }

    /// Resolves the session by the queue item's message first (box IDs can move), then by the
    /// target's slot.
    static func resolve(target: GenerationTarget, messageID: MessageID?, content: BookContent) -> Resolved? {
        guard case let .pageBox(pageID, boxID) = target,
              let page = content.pages[pageID],
              let template = content.template(for: page),
              let box = template.box(boxID), box.content == .image,
              let slot = page.images[boxID]
        else { return nil }
        let session = messageID.flatMap { content.session(containing: $0) } ?? content.sessions[slot.sessionID]
        guard let session else { return nil }
        return Resolved(page: page, template: template, box: box, session: session)
    }

    /// The images this request needs, in send order: base, style references, attached references.
    /// Not yet capped; `assemble` applies the model's limits. Nil if the target is gone.
    public static func plan(intent: GenerationIntent, target: GenerationTarget, messageID: MessageID? = nil,
                            content: BookContent) -> [PlannedImage]? {
        guard let resolved = resolve(target: target, messageID: messageID, content: content) else { return nil }
        let session = resolved.session
        var planned: [PlannedImage] = []
        var seen = Set<ImageRef>()
        func add(_ image: PlannedImage) {
            if seen.insert(image.ref).inserted { planned.append(image) }
        }
        if let refines = intent.refines, let version = session.version(refines) {
            let number = session.versionNumber(refines).map { " (v\($0))" } ?? ""
            add(PlannedImage(ref: version.image, role: "base", label: "Current illustration\(number)",
                             pixelSize: version.pixelSize))
        }
        for (index, ref) in content.style.styleReferences.enumerated() {
            add(PlannedImage(ref: ref, role: "style", label: "Style reference \(index + 1)", pixelSize: nil))
        }
        for attached in intent.attachedReferences {
            guard let other = content.sessions[attached.sessionID],
                  let version = other.version(attached.versionID) else { continue }
            let number = other.versionNumber(attached.versionID).map { " v\($0)" } ?? ""
            add(PlannedImage(ref: version.image, role: "reference", label: "Reference\(number)",
                             pixelSize: version.pixelSize))
        }
        return planned
    }

    /// `imageData` holds the bytes the queue managed to load for `plan`'s refs.
    public static func assemble(intent: GenerationIntent, target: GenerationTarget, messageID: MessageID? = nil,
                                content: BookContent, model: CatalogModel,
                                imageData: [ImageRef: Data] = [:]) throws(AssemblyError) -> (ImageRequest, AssemblyReport) {
        guard let resolved = resolve(target: target, messageID: messageID, content: content),
              let planned = plan(intent: intent, target: target, messageID: messageID, content: content)
        else { throw .targetGone }
        let (page, template, box, session) = (resolved.page, resolved.template, resolved.box, resolved.session)
        if let refines = intent.refines, session.version(refines) == nil { throw .baseVersionGone }

        let style = content.style
        let storyText = page.storyText(in: template)
        let includeStory = intent.includeStoryText && !storyText.isEmpty
        let aspect = content.boxAspect(box, in: template)
        let caps = model.image

        // Pick what fits. The base goes first; overflow and missing bytes are omitted, never dropped silently.
        var sent: [(plan: PlannedImage, payload: ImagePayload)] = []
        var omitted: [SentReference] = []
        var bytes = 0
        for image in planned {
            func omit(_ reason: String) {
                omitted.append(SentReference(image: image.ref, role: image.role, label: "\(image.label) (\(reason))"))
            }
            guard let data = imageData[image.ref] else {
                if image.role == "base" { throw .baseImageMissing }
                omit("file missing")
                continue
            }
            if data.count > caps.maxImageBytes {
                if image.role == "base" { throw .baseImageTooLarge }
                omit("too large")
                continue
            }
            if sent.count >= caps.maxReferenceImages || bytes + data.count > caps.maxRequestBytes {
                if image.role == "base" { throw .baseImageTooLarge }
                omit("over the limit")
                continue
            }
            bytes += data.count
            var entry = image
            entry.pixelSize = image.pixelSize ?? ImageHeader.pixelSize(of: data)
            sent.append((entry, ImagePayload(data: data, contentType: image.ref.contentType, ref: image.ref,
                                             pixelSize: entry.pixelSize)))
        }

        // Prompt sections (A §7.3).
        let styleIndexes = sent.enumerated().filter { $0.element.plan.role == "style" }.map { $0.offset + 1 }
        var styleText = style.visualDescription.trimmed
        if let first = styleIndexes.first, let last = styleIndexes.last {
            let range = first == last ? "Image \(first) is a style reference" : "Images \(first)–\(last) are style references"
            let note = PromptTemplates.render(PromptTemplates.text(for: "style-references") ?? "{{range}}.", ["range": range])
            styleText = styleText.isEmpty ? note : styleText + " " + note
        }
        let isRefinement = sent.first?.plan.role == "base"
        var earlier: [String] = []
        if isRefinement, let refines = intent.refines {
            earlier = session.lineageInstructions(of: refines).map { $0.text.trimmed }.filter { !$0.isEmpty }
        }
        let history = earlier.enumerated().map { "\($0.offset + 1)) \($0.element)" }.joined(separator: "; ")
        let composition = ["aspect": describeAspect(aspect),
                           "calm": calmGuidance(box: box, template: template),
                           "fold": foldGuidance(box: box, template: template),
                           "safe": safeAreaGuidance(box: box, template: template, content: content)]
        let legend = sent.enumerated().map { index, entry in
            PromptTemplates.render(PromptTemplates.text(for: "legend-\(entry.plan.role)") ?? "Image {{n}}.",
                                   ["n": "\(index + 1)"])
        }.joined(separator: "\n")

        let values: [(key: String, placeholders: [String: String], required: Bool)] = [
            ("role", [:], true),
            ("style", ["style": styleText], !styleText.isEmpty),
            ("avoid", ["avoid": style.negativeGuidance.trimmed], !style.negativeGuidance.trimmed.isEmpty),
            ("composition", composition, true),
            ("story", ["story": storyText], includeStory),
            ("history", ["earlier": history], !history.isEmpty),
            ("request", ["request": intent.messageText.trimmed], !intent.messageText.trimmed.isEmpty),
            ("legend", ["lines": legend], !legend.isEmpty),
        ]
        let sections = values.compactMap { entry -> ComposedPrompt.Section? in
            guard entry.required, let template = PromptTemplates.text(for: entry.key) else { return nil }
            return .init(key: entry.key, text: PromptTemplates.render(template, entry.placeholders))
        }
        let prompt = ComposedPrompt(sections: sections)

        // Refinements keep the base image's size (A §7.6); new images use §7.5 fitting.
        let exactSize = isRefinement ? sent.first?.plan.pixelSize : nil
        let baseImage = isRefinement ? sent.first?.payload : nil
        let references = sent.dropFirst(isRefinement ? 1 : 0).map {
            ReferenceImage(payload: $0.payload, sent: SentReference(image: $0.plan.ref, role: $0.plan.role, label: $0.plan.label))
        }
        let request = ImageRequest(model: model, quality: intent.quality,
                                   output: OutputShape(boxAspect: aspect, exactSize: exactSize),
                                   instruction: prompt, baseImage: baseImage, references: references)
        let report = AssemblyReport(
            promptText: prompt.rendered,
            referencesSent: sent.map { SentReference(image: $0.plan.ref, role: $0.plan.role, label: $0.plan.label) },
            referencesOmitted: omitted, storyTextIncluded: includeStory, styleRevision: style.visualRevision,
            estimatedInputBytes: prompt.rendered.utf8.count + bytes)
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

    /// Leading-space sentence about a spread's fold crossing the image, or "".
    static func foldGuidance(box: Box, template: Template) -> String {
        guard template.kind == .spread, box.frame.width > 0 else { return "" }
        let position = (0.5 - box.frame.x) / box.frame.width
        guard position > 0.03, position < 0.97 else { return "" }
        let percent = Int((position * 100).rounded())
        return " " + PromptTemplates.render(PromptTemplates.text(for: "fold") ?? "{{percent}}%",
                                            ["percent": "\(percent)"])
    }

    /// Leading-space sentence about the trimmed outer edge when the box bleeds, or "". Geometry follows
    /// `BookContent.boxAspect`: bleed pushes out the box's `bleedEdges` (not at a spread's fold), and
    /// the page margin counts as unsafe on top of the bleed.
    static func safeAreaGuidance(box: Box, template: Template, content: BookContent) -> String {
        let setup = content.style.pageSetup
        let bleed = setup.bleedEnabled ? max(0, setup.bleedAmount) : 0
        guard bleed > 0 else { return "" }
        let spread = template.kind == .spread
        let trimW = setup.trimSize.width * (spread ? 2 : 1), trimH = setup.trimSize.height
        var edges = box.bleedEdges
        if spread {
            let fold = trimW / 2
            if abs(box.frame.x * trimW - fold) <= 0.5 { edges.remove(.leading) }
            if abs(box.frame.maxX * trimW - fold) <= 0.5 { edges.remove(.trailing) }
        }
        guard !edges.isEmpty else { return "" }
        let m = setup.margins
        func inset(_ edge: EdgeSet, _ margin: Double) -> Double { edges.contains(edge) ? bleed + max(0, margin) : 0 }
        func extra(_ edge: EdgeSet) -> Double { edges.contains(edge) ? bleed : 0 }
        let imageW = box.frame.width * trimW + extra(.leading) + extra(.trailing)
        let imageH = box.frame.height * trimH + extra(.top) + extra(.bottom)
        guard imageW > 0, imageH > 0 else { return "" }
        func percent(_ value: Double) -> Int { max(10, min(99, Int((value * 100 / 5).rounded(.down)) * 5)) }
        let safeW = (imageW - inset(.leading, m.leading) - inset(.trailing, m.trailing)) / imageW
        let safeH = (imageH - inset(.top, m.top) - inset(.bottom, m.bottom)) / imageH
        let horizontal = !edges.isDisjoint(with: [.leading, .trailing])
        let vertical = !edges.isDisjoint(with: [.top, .bottom])
        let area: String
        switch (horizontal, vertical) {
        case (true, true):
            let w = percent(safeW), h = percent(safeH)
            area = w == h ? "the central \(w)% of the image" : "the central \(w)% horizontally and \(h)% vertically"
        case (true, false): area = "the central \(percent(safeW))% horizontally"
        default: area = "the central \(percent(safeH))% vertically"
        }
        return " " + PromptTemplates.render(PromptTemplates.text(for: "safe-area") ?? "{{area}}", ["area": area])
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

/// Reads pixel dimensions from an image header (ImageIO), without decoding.
enum ImageHeader {
    static func pixelSize(of data: Data) -> PixelSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0 else { return nil }
        return PixelSize(width: w, height: h)
    }
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
