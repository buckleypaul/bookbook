import BBAI
import BBModel
import Foundation

/// Pure helpers behind "Draft all empty boxes" (PD §8.5) and the queue's display labels.
public enum DraftAllPlanner {
    /// The message text each Draft-all item sends (the story text carries the scene).
    public static let messageText = "Draft illustration"

    /// Every image box with no placed image and no request pending for it, in reading order:
    /// the cover (if its template has image boxes), then story pages; boxes in template order.
    /// `isPending` says whether a session message still has a live queue item.
    public static func emptyTargets(in content: BookContent,
                                    isPending: (Message) -> Bool) -> [(page: PageID, box: BoxID)] {
        var out: [(page: PageID, box: BoxID)] = []
        for pageID in content.pageIDsCoverFirst {
            guard let page = content.pages[pageID], let template = content.template(for: page) else { continue }
            for box in template.imageBoxes {
                guard let slot = page.images[box.id], slot.placement == nil,
                      let session = content.sessions[slot.sessionID],
                      !session.messages.contains(where: isPending) else { continue }
                out.append((pageID, box.id))
            }
        }
        return out
    }

    /// "Cover" or "Page N" (story pages numbered from 1 in reading order) and "Image N" (the
    /// box's position among the template's image boxes).
    public static func display(page pageID: PageID, box boxID: BoxID, in content: BookContent) -> QueueItemDisplay {
        let pageLabel = WhereUsedText.pageLabel(pageID, in: content)
        let boxes = content.pages[pageID].flatMap { content.template(for: $0) }?.imageBoxes ?? []
        let boxLabel = boxes.firstIndex { $0.id == boxID }.map { "Image \($0 + 1)" } ?? "Image"
        return QueueItemDisplay(bookTitle: content.book.title, pageLabel: pageLabel, boxLabel: boxLabel)
    }
}
