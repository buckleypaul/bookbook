import BBAICore
import BBModel
import Foundation

// Phase 12 contract (main thread); body filled by the BBAI lane. A §7.7.

public enum TemplateDraftError: Error, Hashable, Sendable {
    /// No usable box survived normalization.
    case noBoxes
}

public enum TemplateNormalizer {
    /// Validates and normalizes a draft into a new `Template` (A §7.7): clamp to 0…1, snap edges
    /// within 2% of a margin or the trim edge to it, mark boxes touching the trim edge as bleed
    /// boxes, drop degenerate boxes, ensure at least one box. `kind` is `.single` or `.spread`.
    public static func template(from draft: TemplateDraft, kind: TemplateKind,
                                pageSetup: PageSetup) throws(TemplateDraftError) -> Template {
        fatalError("Phase 12: TemplateNormalizer not implemented")
    }
}
