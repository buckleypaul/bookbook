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
                            dateFormatter: (Date) -> String = defaultDate) -> [DetailRow] {
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
            rows.append(DetailRow(label: "Size", value: version.pixelSize.description))
            rows.append(DetailRow(label: "Date", value: dateFormatter(version.createdAt)))
            return rows
        }
        rows.append(DetailRow(label: "Provider", value: providerName(p.provider)))
        rows.append(DetailRow(label: "Model", value: p.model))
        rows.append(DetailRow(label: "Quality", value: qualityName(p.quality)))
        rows.append(DetailRow(label: "Output size", value: p.outputSize.description))
        rows.append(DetailRow(label: "Your request", value: p.intent.messageText))
        rows.append(DetailRow(label: "Prompt sent", value: p.promptSent))
        for key in p.parametersSent.keys.sorted() {
            rows.append(DetailRow(label: "Parameter \(key)", value: p.parametersSent[key] ?? ""))
        }
        rows.append(DetailRow(label: "References sent", value: references(p.referencesSent)))
        if !p.referencesOmitted.isEmpty {
            rows.append(DetailRow(label: "References left out", value: references(p.referencesOmitted)))
        }
        rows.append(DetailRow(label: "Story text included", value: p.storyTextIncluded ? "Yes" : "No"))
        rows.append(DetailRow(label: "Cost", value: "—"))
        rows.append(DetailRow(label: "Style revision", value: String(p.styleRevision)))
        rows.append(DetailRow(label: "Usage", value: p.usage.map(usageText) ?? "Not reported"))
        if let revised = p.revisedPrompt, !revised.isEmpty {
            rows.append(DetailRow(label: "Revised prompt", value: revised))
        }
        rows.append(DetailRow(label: "Image size", value: version.pixelSize.description))
        rows.append(DetailRow(label: "Date", value: dateFormatter(version.createdAt)))
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

    static func usageText(_ u: TokenUsage) -> String {
        "input text \(u.inputTextTokens), input image \(u.inputImageTokens), cached \(u.cachedInputTokens), "
            + "output text \(u.outputTextTokens), output image \(u.outputImageTokens) tokens"
    }
}
