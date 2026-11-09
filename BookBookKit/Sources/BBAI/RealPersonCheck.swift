import BBAICore
import BBModel
import Foundation

// Phase 10 contract (main thread); the AI lane implements it.

extension ContextAssembler {
    /// True when assembling `intent` for `target` now would send at least one image whose
    /// version has `depictsRealPerson == true` (after reference selection and caps, A §11).
    public static func sendsRealPersonPhoto(intent: GenerationIntent, target: GenerationTarget,
                                            content: BookContent, model: CatalogModel) -> Bool { false }
}
