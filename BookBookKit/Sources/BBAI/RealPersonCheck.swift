import BBAICore
import BBModel
import Foundation

// Phase 10 contract (main thread); the AI lane implements it.

extension ContextAssembler {
    /// True when assembling `intent` for `target` now would send at least one image whose
    /// version has `depictsRealPerson == true` (after reference selection and caps, A §11).
    ///
    /// Bytes aren't loaded here, so the model's image-count limit is applied but not the byte
    /// budget (every image counts as fitting); a photo the byte budget would drop still counts.
    public static func sendsRealPersonPhoto(intent: GenerationIntent, target: GenerationTarget,
                                            content: BookContent, model: CatalogModel) -> Bool {
        guard let prepared = prepare(intent: intent, target: target, messageID: nil, content: content) else { return false }
        let sizes = Dictionary(prepared.candidates.map { ($0.ref, 0) }, uniquingKeysWith: { first, _ in first })
        return ReferenceSelector.select(prepared.candidates, byteCounts: sizes, limits: limits(model))
            .sent.contains { $0.depictsRealPerson }
    }
}
