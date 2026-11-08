import BBAI
import BBModel
import Foundation

/// Plain-language money and time strings (PD §5, A §7.10). Pure, so they can be tested.
public enum CostText {
    /// `$0.07`; amounts under a cent keep four places (`$0.0059`) so small Draft costs don't read as zero.
    public static func amount(_ value: Decimal) -> String {
        let places = (value != 0 && abs(value) < Decimal(string: "0.01")!) ? 4 : 2
        return "$" + plain(value, places: places)
    }

    /// `about $0.07` or `cost unknown`.
    public static func estimate(_ estimate: CostEstimate) -> String {
        guard let amount = estimate.amount else { return "cost unknown" }
        return "about " + Self.amount(amount)
    }

    /// `$0.0059 (estimate)` or `$0.06 (actual)`.
    public static func record(_ record: CostRecord) -> String {
        amount(record.amount) + " (" + basisLabel(record.basis) + ")"
    }

    public static func basisLabel(_ basis: CostBasis) -> String { basis == .actual ? "actual" : "estimate" }

    /// `0:42 of ~1:10`, or just `0:42` when the typical duration is unknown.
    public static func elapsedOfTypical(elapsed: TimeInterval, typical: Double?) -> String {
        guard let typical, typical > 0 else { return ElapsedTimeText.clock(elapsed) }
        return "\(ElapsedTimeText.clock(elapsed)) of ~\(ElapsedTimeText.clock(typical))"
    }

    public static func requestConfirmation(_ estimate: CostEstimate) -> String {
        "This request is \(Self.estimate(estimate)). Generate?"
    }

    public static func budgetWarning(spent: Decimal, budget: Decimal) -> String {
        "This book has spent \(amount(spent)) of its \(amount(budget)) budget. Generate anyway?"
    }

    /// The alert text before one request, or nil when neither the threshold nor the budget applies.
    /// Both can apply; the answer never blocks (A §7.10).
    public static func requestAlert(estimate: CostEstimate, decision: CostDecision, spent: Decimal,
                                    budget: Decimal?) -> String? {
        var parts: [String] = []
        if decision.needsConfirmation { parts.append("This request is \(Self.estimate(estimate)).") }
        if decision.overBudget, let budget {
            parts.append("This book has spent \(amount(spent)) of its \(amount(budget)) budget.")
        }
        guard !parts.isEmpty else { return nil }
        parts.append(decision.overBudget ? "Generate anyway?" : "Generate?")
        return parts.joined(separator: " ")
    }

    /// The Draft All Empty Boxes confirmation: always shown.
    public static func batchAlert(count: Int, estimate: CostEstimate, decision: CostDecision, spent: Decimal,
                                  budget: Decimal?) -> String {
        var text = "\(count) \(count == 1 ? "request" : "requests"), \(Self.estimate(estimate))."
        if decision.overBudget, let budget {
            text += " This book has spent \(amount(spent)) of its \(amount(budget)) budget."
        }
        return text
    }

    public static func kindName(_ kind: CostKind) -> String {
        switch kind {
        case .image: "Pictures"
        case .consistency: "Consistency checks"
        case .template: "Layout suggestions"
        }
    }

    public static func statusName(_ status: CostStatus) -> String {
        switch status {
        case .completed: "Completed"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }

    public enum Parsed: Equatable { case empty, value(Decimal), invalid }

    /// Parses a Settings money field: empty is `.empty`; negatives and junk are `.invalid`.
    public static func parse(_ text: String) -> Parsed {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("$") { t.removeFirst() }
        if t.isEmpty { return .empty }
        guard let d = Decimal(string: t, locale: Locale(identifier: "en_US_POSIX")), d >= 0 else { return .invalid }
        return .value(d)
    }

    /// An editable plain string for a Decimal (no currency symbol).
    public static func field(_ value: Decimal) -> String { NSDecimalNumber(decimal: value).stringValue }

    private static func plain(_ value: Decimal, places: Int) -> String {
        var rounded = Decimal()
        var v = value
        NSDecimalRound(&rounded, &v, places, .plain)
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.numberStyle = .decimal
        f.minimumFractionDigits = places
        f.maximumFractionDigits = places
        f.usesGroupingSeparator = false
        return f.string(from: NSDecimalNumber(decimal: rounded)) ?? "\(rounded)"
    }
}
