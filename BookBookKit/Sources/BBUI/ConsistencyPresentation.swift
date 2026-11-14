import BBModel
import Foundation

/// Phase 12 (PD §8.9): how a consistency report is shown, as pure data.
public enum ConsistencyPresentation {
    /// The differences, major first (the model's order within a severity).
    public static func sortedDifferences(_ report: ConsistencyReport) -> [ConsistencyDifference] {
        report.differences.filter { $0.severity == .major } + report.differences.filter { $0.severity == .minor }
    }

    /// "Pip — scarf: blue; reference is red" (no asset: "palette: ...").
    public static func line(_ difference: ConsistencyDifference) -> String {
        let subject = difference.asset.map { "\($0) — " } ?? ""
        return "\(subject)\(difference.aspect): \(difference.observed); reference is \(difference.expected)"
    }

    public static func lines(_ report: ConsistencyReport) -> [String] {
        sortedDifferences(report).map(line)
    }

    /// One-line result: "Consistent with the references", "Differences found (1 major, 2 minor)", …
    public static func resultText(_ report: ConsistencyReport) -> String {
        if report.differences.isEmpty { return "Consistent with the references" }
        let major = report.differences.filter { $0.severity == .major }.count
        let minor = report.differences.count - major
        var parts: [String] = []
        if major > 0 { parts.append("\(major) major") }
        if minor > 0 { parts.append("\(minor) minor") }
        let base = "Differences found (\(parts.joined(separator: ", ")))"
        if report.dismissed, report.warns { return base + ", warning dismissed" }
        return base
    }

    /// Why Check Consistency is unavailable, or nil.
    public static func checkUnavailableReason(canCheck: Bool, isEditable: Bool, isOnline: Bool, hasKey: Bool,
                                              isPending: Bool) -> String? {
        if !isEditable { return UnavailableText.readOnly }
        if isPending { return "A check of this picture is already queued." }
        if !canCheck { return "No vision model is available. Choose one in Settings ▸ Models." }
        if !isOnline { return UnavailableText.offline }
        if !hasKey { return UnavailableText.noKey }
        return nil
    }

    /// Details rows for a version's latest check (A §11: everything sent is shown).
    public static func detailRows(_ report: ConsistencyReport, cost: CostRecord?,
                                  dateFormatter: (Date) -> String = VersionDetailsContent.defaultDate) -> [DetailRow] {
        var rows = [
            DetailRow(label: "Check model", value: report.model),
            DetailRow(label: "Checked", value: dateFormatter(report.checkedAt)),
            DetailRow(label: "Check result", value: resultText(report)),
        ]
        if !report.differences.isEmpty {
            rows.append(DetailRow(label: "Differences", value: lines(report).joined(separator: "\n")))
        }
        rows.append(DetailRow(label: "Check prompt sent", value: report.sent.promptSent))
        rows.append(DetailRow(label: "Check images sent", value: VersionDetailsContent.references(report.sent.imagesSent)))
        if !report.sent.parametersSent.isEmpty {
            rows.append(DetailRow(label: "Check parameters sent",
                                  value: VersionDetailsContent.parametersText(report.sent.parametersSent)))
        }
        rows.append(DetailRow(label: "Check cost", value: cost.map(CostText.record) ?? "—"))
        if let usage = report.usage {
            rows.append(DetailRow(label: "Check usage", value: VersionDetailsContent.usageText(usage)))
        }
        return rows
    }
}
