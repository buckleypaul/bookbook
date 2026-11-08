import Foundation

/// Moves a page's text and images onto a new template's boxes (PD §8.5 "Changing it keeps
/// the text and images and reassigns them to the new boxes where possible", Phase 5).
///
/// Mapping rules (contract):
/// 1. Boxes with a `BoxRole` map to the new box with the same role first.
/// 2. The remaining text boxes map in reading order (frame top, then left; ties by layer
///    order), and likewise image boxes, one to one.
/// 3. Text left over (more old text boxes than new ones) is appended, as extra paragraphs,
///    to the last mapped new text box, so no words are lost. With no new text box at all the
///    text is dropped (undo brings it back).
/// 4. Image slots left over are dropped from the page (their sessions stay in the book).
/// 5. New image boxes that received no slot are listed in `unassignedImageBoxes`; the caller
///    creates their empty sessions.
/// Only `text` and `images` change; everything else on the page is kept except `templateID`.
public enum TemplateReassignment {
    public struct Result: Hashable, Sendable {
        public var page: Page
        public var unassignedImageBoxes: [BoxID]
        public init(page: Page, unassignedImageBoxes: [BoxID]) {
            self.page = page
            self.unassignedImageBoxes = unassignedImageBoxes
        }
    }

    public static func reassign(_ page: Page, from old: Template, to new: Template) -> Result {
        fatalError("Phase 5 lane L1")
    }
}
