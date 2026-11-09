import BBAI
import BBAICore
import BBModel
import BBStore
import Foundation

// Phase 10 contract (main thread). The UI-core lane fills in the bodies.

/// "Generate whole sheet" (PD §8.3): one item per unlocked sheet item, at the user's default
/// quality, with the combined estimate. Nothing is appended or enqueued yet.
public struct SheetBatchPlan: Sendable {
    public var asset: AssetID
    public var items: [QueueItem]
    /// The sheet item each queue item fills, parallel to `items`.
    public var sheetItems: [UUID]
    public var estimate: CostEstimate
    public var count: Int { items.count }

    public init(asset: AssetID, items: [QueueItem] = [], sheetItems: [UUID] = [],
                estimate: CostEstimate = CostEstimate(amount: 0)) {
        self.asset = asset
        self.items = items
        self.sheetItems = sheetItems
        self.estimate = estimate
    }
}

extension AppModel {
    /// Like `generate(prompt:…page:box:in:)` for any target (asset slots and sheet items
    /// included). `prompt` is stored text (mention tokens). Shows nothing itself; callers run
    /// the cost and real-person checks first.
    @discardableResult
    public func generate(prompt: String, quality: QualityLevel, includeStoryText: Bool, refines: VersionID?,
                         attachedReferences: [VersionRef], target: GenerationTarget,
                         in document: BookDocument) -> Bool { false }

    /// Unlocked sheet items with nothing pending (empty or not), planned like Draft all.
    public func sheetBatchPlan(asset: AssetID, in document: BookDocument) -> SheetBatchPlan {
        SheetBatchPlan(asset: asset)
    }

    /// Appends the pending messages and enqueues the plan. False if nothing was queued.
    @discardableResult
    public func enqueueSheetBatch(_ plan: SheetBatchPlan, in document: BookDocument) -> Bool { false }

    /// The provider this request would send a real-person photo to, when the book hasn't
    /// acknowledged that provider's notice yet (A §11); nil = no notice needed.
    public func realPersonNoticeNeeded(intent: GenerationIntent, target: GenerationTarget,
                                       in document: BookDocument) -> ProviderID? { nil }

    /// Record the acknowledgement in `Book.acknowledgements` (not undoable).
    public func acknowledgeRealPersonNotice(_ provider: ProviderID, in document: BookDocument) {}
}
