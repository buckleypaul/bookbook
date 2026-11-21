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
///    Bound boxes (`.title`, `.author`, `.pageNumberSlot`) are never a source or a target of
///    rules 2 and 3 (only of rule 1): body text never lands in them, and a bound box's text
///    with no same-role box in the new template is dropped rather than moved into body text
///    (Phase 16b #70a/#70b). A template with no free text box drops the text.
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

    private static func isBound(_ box: Box) -> Bool {
        switch box.role {
        case .title, .author, .pageNumberSlot: true
        case nil: false
        }
    }

    /// Top to bottom, then left to right; ties keep the layer order.
    private static func readingOrder(_ boxes: [Box]) -> [Box] {
        boxes.enumerated().sorted { a, b in
            let (x, y) = (a.element.frame, b.element.frame)
            if x.y != y.y { return x.y < y.y }
            if x.x != y.x { return x.x < y.x }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// Rules 1 and 2 for one kind of box: each `old` box with a role goes to the first unused
    /// `new` box with that role, then the remaining boxes that are `free` pair up in reading
    /// order. Returns the pairs in the order they are made, and the free old boxes left without
    /// a partner (reading order).
    private static func pair(_ old: [Box], _ new: [Box],
                             free: (Box) -> Bool) -> (pairs: [(from: BoxID, to: BoxID)], leftover: [Box]) {
        var pairs: [(from: BoxID, to: BoxID)] = []
        var usedOld = Set<BoxID>()
        var usedNew = Set<BoxID>()
        for box in old {
            guard let role = box.role,
                  let target = new.first(where: { $0.role == role && !usedNew.contains($0.id) })
            else { continue }
            pairs.append((box.id, target.id))
            usedOld.insert(box.id)
            usedNew.insert(target.id)
        }
        let restOld = readingOrder(old.filter { !usedOld.contains($0.id) && free($0) })
        let restNew = readingOrder(new.filter { !usedNew.contains($0.id) && free($0) })
        for (from, to) in zip(restOld, restNew) { pairs.append((from.id, to.id)) }
        return (pairs, Array(restOld.dropFirst(restNew.count)))
    }

    public static func reassign(_ page: Page, from old: Template, to new: Template) -> Result {
        var result = page
        result.templateID = new.id
        result.text = [:]
        result.images = [:]

        // Text. Bound boxes neither give nor receive body text (Phase 5, 16b); with no free box
        // the text is dropped.
        let newText = new.textBoxes
        let text = pair(old.textBoxes.filter { page.text[$0.id] != nil }, newText) { !isBound($0) }
        for (from, to) in text.pairs { result.text[to] = page.text[from] }
        if !text.leftover.isEmpty,
           let last = readingOrder(newText.filter { result.text[$0.id] != nil && !isBound($0) }).last {
            var target = result.text[last.id] ?? RichText()
            for box in text.leftover {
                target.paragraphs.append(contentsOf: page.text[box.id]?.paragraphs ?? [])
            }
            result.text[last.id] = target
        }

        // Images. Leftover slots are dropped.
        let newImages = new.imageBoxes
        let images = pair(old.imageBoxes.filter { page.images[$0.id] != nil }, newImages) { _ in true }
        for (from, to) in images.pairs { result.images[to] = page.images[from] }

        let unassigned = newImages.filter { result.images[$0.id] == nil }.map(\.id)
        return Result(page: result, unassignedImageBoxes: unassigned)
    }
}
