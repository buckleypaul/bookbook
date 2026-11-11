import BBAI
import BBAICore
import BBModel
@testable import BBUI

extension Fixtures {
    /// The pending message and queue item for `prompt` in a page box, with `GenerationDefaults()`.
    static func generation(_ prompt: String, refines: VersionID? = nil, bookID: BookID, page: PageID,
                           box: BoxID) -> (message: Message, item: QueueItem) {
        let defaults = GenerationDefaults()
        let intent = GenerationIntent(messageText: prompt, refines: refines, provider: defaults.provider,
                                      model: defaults.model, quality: defaults.quality,
                                      includeStoryText: defaults.includeStoryText)
        return BookMutations.makeGeneration(intent: intent, bookID: bookID, target: .pageBox(page, box), now: date)
    }
}
