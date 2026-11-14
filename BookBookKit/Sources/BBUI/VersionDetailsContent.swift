import BBAI
import BBModel
import Foundation

/// One labelled line in Version details.
public struct DetailRow: Hashable, Sendable {
    public var label: String
    public var value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

/// Everything sent for a version, as rows (A §11, plan §2.1: Version details shows it all).
public enum VersionDetailsContent {
    public static func rows(for version: Version, in session: Session? = nil,
                            cost: CostRecord? = nil, assets: [AssetID: Asset] = [:],
                            checkCost: CostRecord? = nil, designCost: CostRecord? = nil,
                            dateFormatter: (Date) -> String = defaultDate,
                            modelName: (ProviderID, String) -> String? = { _, _ in nil }) -> [DetailRow] {
        var rows = baseRows(for: version, in: session, cost: cost, assets: assets, modelName: modelName,
                            dateFormatter: dateFormatter)
        if let style = version.textStyle {
            rows += textStyleRows(style, cost: designCost, isVersionCost: style.call.cost == version.provenance?.cost,
                                  modelName: modelName)
        }
        if let report = version.consistency {
            rows += ConsistencyPresentation.detailRows(report, cost: checkCost, dateFormatter: dateFormatter)
        }
        return rows
    }

    private static func baseRows(for version: Version, in session: Session?, cost: CostRecord?,
                                 assets: [AssetID: Asset], modelName: (ProviderID, String) -> String?,
                                 dateFormatter: (Date) -> String) -> [DetailRow] {
        var rows: [DetailRow] = []
        if let session, let number = session.versionNumber(version.id) {
            rows.append(DetailRow(label: "Version", value: "v\(number)"))
        }
        if let parent = version.parent, let session {
            let text = session.versionNumber(parent).map { "version \($0)" } ?? "a version that was deleted"
            rows.append(DetailRow(label: "Refined from", value: text))
        }
        guard let p = version.provenance else {
            rows.append(DetailRow(label: "Source", value: sourceName(version.source)))
            if let real = version.depictsRealPerson {
                rows.append(DetailRow(label: "Real person photo", value: real ? "Yes" : "No"))
            }
            rows.append(DetailRow(label: "Size", value: sizeText(version.pixelSize)))
            rows.append(DetailRow(label: "Date", value: dateFormatter(version.createdAt)))
            return rows
        }
        if version.source != .generated {
            rows.append(DetailRow(label: "Source", value: sourceName(version.source)))
        }
        rows.append(DetailRow(label: "Provider", value: providerName(p.provider)))
        rows.append(DetailRow(label: "Model", value: modelText(p.model, name: modelName(p.provider, p.model))))
        rows.append(DetailRow(label: "Quality", value: qualityName(p.quality)))
        rows.append(DetailRow(label: "Output size", value: sizeText(p.outputSize)))
        rows.append(DetailRow(label: "Your request",
                              value: MentionText.displayText(p.intent.messageText, assets: assets,
                                                             fallback: deletedAssetName)))
        rows.append(DetailRow(label: "Prompt sent", value: p.promptSent))
        if !p.parametersSent.isEmpty {
            rows.append(DetailRow(label: "Parameters sent", value: parametersText(p.parametersSent)))
        }
        if !p.assetRevisions.isEmpty {
            rows.append(DetailRow(label: "Assets", value: assetList(p.assetRevisions, assets: assets)))
        }
        rows.append(DetailRow(label: "References sent", value: references(p.referencesSent)))
        if !p.referencesOmitted.isEmpty {
            rows.append(DetailRow(label: "Left out", value: references(p.referencesOmitted)))
        }
        if p.maskSent != nil || p.intent.regionMask != nil {
            // Region edit (A §7.6): the mask went with the base image; the version is the local composite.
            rows.append(DetailRow(label: "Mask sent",
                                  value: "\(sizeText(version.pixelSize)) mask (transparent = edit area)"))
        }
        if p.rawOutput != nil {
            let step = p.parametersSent[GenerationQueue.localWhiteKeyParameter] == "true"
                ? "before its white background was made transparent" : "before blending into the original"
            rows.append(DetailRow(label: "Raw provider output",
                                  value: "\(sizeText(p.outputSize)) image, \(step)"))
        }
        if let feather = p.featherPixels {
            rows.append(DetailRow(label: "Feather", value: "\(featherText(feather)) px"))
        }
        rows.append(DetailRow(label: "Story text included", value: p.storyTextIncluded ? "Yes" : "No"))
        rows.append(DetailRow(label: "Cost", value: cost.map(CostText.record) ?? "—"))
        rows.append(DetailRow(label: "Style revision", value: String(p.styleRevision)))
        rows.append(DetailRow(label: "Usage", value: p.usage.map(usageText) ?? "Not reported"))
        if let revised = p.revisedPrompt, !revised.isEmpty {
            rows.append(DetailRow(label: "Revised prompt", value: revised))
        }
        if version.pixelSize != p.outputSize {
            rows.append(DetailRow(label: "Image size", value: sizeText(version.pixelSize)))
        }
        rows.append(DetailRow(label: "Date", value: dateFormatter(version.createdAt)))
        return rows
    }

    /// AI text styling (A §7.13): the design the text model chose and everything sent to it.
    /// For a typography-only version the rows above describe this same request.
    static func textStyleRows(_ style: TextStyleIntent, cost: CostRecord?, isVersionCost: Bool,
                              modelName: (ProviderID, String) -> String? = { _, _ in nil }) -> [DetailRow] {
        var rows: [DetailRow] = [DetailRow(label: "Design", value: style.summary)]
        let s = style.styling
        rows.append(DetailRow(label: "Font", value: s.font?.postScriptName ?? "Unchanged"))
        rows.append(DetailRow(label: "Font size", value: s.fontSize.map { "\(featherText($0)) pt" } ?? "Unchanged"))
        rows.append(DetailRow(label: "Text colour", value: s.color.map(hex) ?? "Unchanged"))
        rows.append(DetailRow(label: "Alignment", value: s.alignment?.rawValue.capitalized ?? "Unchanged"))
        rows.append(DetailRow(label: "Text inset", value: "\(Int((s.insetFraction * 100).rounded()))% of the box"))
        rows.append(DetailRow(label: "Panel", value: s.background.map(hex) ?? "None"))
        rows.append(DetailRow(label: "Decoration", value: style.decorationPrompt ?? "None (typography only)"))
        rows.append(DetailRow(label: "Design model",
                              value: "\(providerName(style.call.provider)) "
                                  + modelText(style.call.model, name: modelName(style.call.provider, style.call.model))))
        rows.append(DetailRow(label: "Design system prompt", value: style.call.system))
        rows.append(DetailRow(label: "Design prompt", value: style.call.user))
        if !style.call.parametersSent.isEmpty {
            rows.append(DetailRow(label: "Design parameters sent", value: parametersText(style.call.parametersSent)))
        }
        rows.append(DetailRow(label: "Design usage", value: style.call.usage.map(usageText) ?? "Not reported"))
        rows.append(DetailRow(label: "Design cost", value: isVersionCost ? "Included in Cost" : cost.map(CostText.record) ?? "—"))
        return rows
    }

    public static func defaultDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    public static func providerName(_ provider: ProviderID) -> String {
        switch provider {
        case .openai: "OpenAI"
        case .gemini: "Google Gemini"
        default: provider.rawValue
        }
    }

    public static func qualityName(_ quality: QualityLevel) -> String {
        switch quality {
        case .draft: "Draft"
        case .standard: "Standard"
        case .high: "High"
        }
    }

    /// `#RRGGBB` (with the alpha as a percentage when not opaque).
    static func hex(_ color: RGBA) -> String {
        func byte(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        let text = String(format: "#%02X%02X%02X", byte(color.red), byte(color.green), byte(color.blue))
        return color.alpha < 1 ? text + " (\(Int((color.alpha * 100).rounded()))%)" : text
    }

    static func featherText(_ pixels: Double) -> String {
        pixels.rounded() == pixels ? String(Int(pixels)) : String(format: "%.1f", pixels)
    }

    static func sourceName(_ source: VersionSource) -> String {
        switch source {
        case .generated: "Generated"
        case .imported: "Imported"
        case .regionEdit: "Region edit"
        case .consistencyFix: "Consistency fix"
        }
    }

    static func references(_ refs: [SentReference]) -> String {
        refs.isEmpty ? "None" : refs.map { "\($0.label) (\($0.role))" }.joined(separator: ", ")
    }

    /// How a mention of an asset that's gone is shown.
    static let deletedAssetName = "(deleted asset)"

    /// "Granny Oak (revision 2), Pip (revision 3)": by name, assets that are gone last.
    static func assetList(_ revisions: [AssetID: Int], assets: [AssetID: Asset]) -> String {
        let named = revisions.map { (name: assets[$0.key]?.name, revision: $0.value) }
        let known = named.compactMap { item in item.name.map { ($0, item.revision) } }
            .sorted { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
            .map { "\($0.0) (revision \($0.1))" }
        let gone = named.filter { $0.name == nil }.count
        return (known + (gone > 0 ? ["\(gone) deleted asset\(gone == 1 ? "" : "s")"] : [])).joined(separator: ", ")
    }

    /// Two lines: "Input: 120 text, 56 image tokens (0 cached)" and "Output: 0 text, 4160 image tokens".
    static func usageText(_ u: TokenUsage) -> String {
        "Input: \(u.inputTextTokens) text, \(u.inputImageTokens) image tokens (\(u.cachedInputTokens) cached)\n"
            + "Output: \(u.outputTextTokens) text, \(u.outputImageTokens) image tokens"
    }

    /// The parameters sent, one "key: value" line each, by key.
    static func parametersText(_ parameters: [String: String]) -> String {
        parameters.keys.sorted().map { "\($0): \(parameters[$0] ?? "")" }.joined(separator: "\n")
    }

    /// "1024 × 1536".
    static func sizeText(_ size: PixelSize) -> String { "\(size.width) × \(size.height)" }

    /// "GPT Image 2.5 Sunburst (gpt-image-2.5-sunburst)"; the bare ID when the catalog doesn't
    /// know the model any more; the name alone when it already includes the ID (custom models).
    static func modelText(_ id: String, name: String?) -> String {
        guard let name else { return id }
        return name.contains(id) ? name : "\(name) (\(id))"
    }
}
