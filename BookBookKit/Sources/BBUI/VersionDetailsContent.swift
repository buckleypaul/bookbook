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
                            dateFormatter: (Date) -> String = defaultDate) -> [DetailRow] {
        var rows = baseRows(for: version, in: session, cost: cost, assets: assets, dateFormatter: dateFormatter)
        if let style = version.textStyle {
            rows += textStyleRows(style, cost: designCost, isVersionCost: style.call.cost == version.provenance?.cost)
        }
        if let report = version.consistency {
            rows += ConsistencyPresentation.detailRows(report, cost: checkCost, dateFormatter: dateFormatter)
        }
        return rows
    }

    private static func baseRows(for version: Version, in session: Session?, cost: CostRecord?,
                                 assets: [AssetID: Asset], dateFormatter: (Date) -> String) -> [DetailRow] {
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
            rows.append(DetailRow(label: "Size", value: version.pixelSize.description))
            rows.append(DetailRow(label: "Date", value: dateFormatter(version.createdAt)))
            return rows
        }
        if version.source != .generated {
            rows.append(DetailRow(label: "Source", value: sourceName(version.source)))
        }
        rows.append(DetailRow(label: "Provider", value: providerName(p.provider)))
        rows.append(DetailRow(label: "Model", value: p.model))
        rows.append(DetailRow(label: "Quality", value: qualityName(p.quality)))
        rows.append(DetailRow(label: "Output size", value: p.outputSize.description))
        rows.append(DetailRow(label: "Your request",
                              value: MentionText.displayText(p.intent.messageText, assets: assets,
                                                             fallback: deletedAssetName)))
        rows.append(DetailRow(label: "Prompt sent", value: p.promptSent))
        for key in p.parametersSent.keys.sorted() {
            rows.append(DetailRow(label: "Parameter \(key)", value: p.parametersSent[key] ?? ""))
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
                                  value: "\(version.pixelSize.width)x\(version.pixelSize.height) mask (transparent = edit area)"))
        }
        if p.rawOutput != nil {
            rows.append(DetailRow(label: "Raw provider output",
                                  value: "\(p.outputSize.width)x\(p.outputSize.height) image, before blending into the original"))
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
        rows.append(DetailRow(label: "Image size", value: version.pixelSize.description))
        rows.append(DetailRow(label: "Date", value: dateFormatter(version.createdAt)))
        return rows
    }

    /// AI text styling (A §7.13): the design the text model chose and everything sent to it.
    /// For a typography-only version the rows above describe this same request.
    static func textStyleRows(_ style: TextStyleIntent, cost: CostRecord?, isVersionCost: Bool) -> [DetailRow] {
        var rows: [DetailRow] = [DetailRow(label: "Design", value: style.summary)]
        let s = style.styling
        rows.append(DetailRow(label: "Font", value: s.font?.postScriptName ?? "Unchanged"))
        rows.append(DetailRow(label: "Font size", value: s.fontSize.map { "\(featherText($0)) pt" } ?? "Unchanged"))
        rows.append(DetailRow(label: "Text colour", value: s.color.map(hex) ?? "Unchanged"))
        rows.append(DetailRow(label: "Alignment", value: s.alignment?.rawValue.capitalized ?? "Unchanged"))
        rows.append(DetailRow(label: "Text inset", value: "\(Int((s.insetFraction * 100).rounded()))% of the box"))
        rows.append(DetailRow(label: "Panel", value: s.background.map(hex) ?? "None"))
        rows.append(DetailRow(label: "Decoration", value: style.decorationPrompt ?? "None (typography only)"))
        rows.append(DetailRow(label: "Design model", value: "\(providerName(style.call.provider)) \(style.call.model)"))
        rows.append(DetailRow(label: "Design system prompt", value: style.call.system))
        rows.append(DetailRow(label: "Design prompt", value: style.call.user))
        for key in style.call.parametersSent.keys.sorted() {
            rows.append(DetailRow(label: "Design parameter \(key)", value: style.call.parametersSent[key] ?? ""))
        }
        rows.append(DetailRow(label: "Design usage", value: style.call.usage.map(usageText) ?? "Not reported"))
        rows.append(DetailRow(label: "Design cost", value: isVersionCost ? "The Cost above" : cost.map(CostText.record) ?? "—"))
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

    static func usageText(_ u: TokenUsage) -> String {
        "input text \(u.inputTextTokens), input image \(u.inputImageTokens), cached \(u.cachedInputTokens), "
            + "output text \(u.outputTextTokens), output image \(u.outputImageTokens) tokens"
    }
}
