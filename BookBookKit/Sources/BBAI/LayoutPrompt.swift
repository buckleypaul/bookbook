import BBAICore
import BBModel
import Foundation

// Phase 12 contract (main thread); body filled by the BBAI lane. A §7.7.

public enum LayoutPrompt {
    /// Renders the layout request: the description, the page setup (size, orientation, margins,
    /// bleed, single or spread) and two presets of the same `kind` as few-shot examples.
    public static func request(description: String, kind: TemplateKind, pageSetup: PageSetup,
                               presets: [Template], model: CatalogTextModel) -> LayoutRequest {
        fatalError("Phase 12: LayoutPrompt not implemented")
    }

    /// A preset as a few-shot `TemplateDraft` (the inverse of `TemplateNormalizer`).
    public static func draft(from template: Template, pageSetup: PageSetup) -> TemplateDraft {
        fatalError("Phase 12: LayoutPrompt not implemented")
    }
}
