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

    /// The alert text before one request, or nil when neither the threshold nor the budget applies.
    /// Both can apply; the answer never blocks (A §7.10). `question` names the action without its
    /// question mark ("Check this picture"), so the alert asks about what the button does.
    public static func requestAlert(estimate: CostEstimate, decision: CostDecision, spent: Decimal,
                                    budget: Decimal?, question: String = "Generate") -> String? {
        var parts: [String] = []
        if decision.needsConfirmation { parts.append("This request is \(Self.estimate(estimate)).") }
        if decision.overBudget, let budget {
            parts.append("This book has spent \(amount(spent)) of its \(amount(budget)) budget.")
        }
        guard !parts.isEmpty else { return nil }
        parts.append(decision.overBudget ? "\(question) anyway?" : "\(question)?")
        return parts.joined(separator: " ")
    }

    /// The Draft All Empty Boxes confirmation: always shown. `pageCount` is the number of
    /// distinct story pages in the batch (a page can have several empty boxes); without it, every
    /// picture but the cover's counts as a page. The confirmation-limit remark follows the
    /// estimate it's about, then the budget.
    public static func batchAlert(count: Int, estimate: CostEstimate, decision: CostDecision, spent: Decimal,
                                  budget: Decimal?, coverIncluded: Bool = false, pageCount: Int? = nil) -> String {
        let pictures = "\(count) \(count == 1 ? "picture" : "pictures")"
        let pages = pageCount ?? (count - 1)
        let noun = coverIncluded && pages > 0
            ? "\(pictures) (cover + \(pages) \(pages == 1 ? "page" : "pages"))"
            : pictures
        var text = "\(noun), \(Self.estimate(estimate))."
        if decision.needsConfirmation { text += " That's above your confirmation limit." }
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
        case .textStyle: "Text style designs"
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
