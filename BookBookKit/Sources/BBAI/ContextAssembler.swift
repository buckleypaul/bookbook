import BBAICore
import BBModel
import Foundation

// Owned by the AI lane. Contract stub: signatures are frozen, bodies are placeholders.

/// Builds the provider-neutral request from a book snapshot (A §7.3). Pure; snapshot-tested.
public enum ContextAssembler {
    /// Returns nil if the target page, box or session no longer exists.
    public static func assemble(intent: GenerationIntent, target: GenerationTarget, content: BookContent,
                                model: CatalogModel) -> (ImageRequest, AssemblyReport)? {
        fatalError("Phase 2 AI lane: not implemented")
    }
}
