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
///    Bound `.title`/`.author` boxes are never a target of rules 2 and 3 (only of rule 1), so
///    body text never lands in them; a template with no free text box drops the text.
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

    private static func isBound(_ box: Box) -> Bool { box.role == .title || box.role == .author }

    public static func reassign(_ page: Page, from old: Template, to new: Template) -> Result {
        var result = page
        result.templateID = new.id
        result.text = [:]
        result.images = [:]

        func readingOrder(_ boxes: [Box]) -> [Box] {
            boxes.enumerated().sorted { a, b in
                let (x, y) = (a.element.frame, b.element.frame)
                if x.y != y.y { return x.y < y.y }
                if x.x != y.x { return x.x < y.x }
                return a.offset < b.offset
            }.map(\.element)
        }

        // Text.
        let oldText = old.textBoxes.filter { page.text[$0.id] != nil }
        let newText = new.textBoxes
        var usedOldText = Set<BoxID>()
        var usedNewText = Set<BoxID>()
        for box in oldText {
            guard let role = box.role,
                  let target = newText.first(where: { $0.role == role && !usedNewText.contains($0.id) })
            else { continue }
            result.text[target.id] = page.text[box.id]
            usedOldText.insert(box.id)
            usedNewText.insert(target.id)
        }
        let restOldText = readingOrder(oldText.filter { !usedOldText.contains($0.id) })
        // Bound title/author boxes never receive body text (Phase 5); with no free box the text is dropped.
        let restNewText = readingOrder(newText.filter { !usedNewText.contains($0.id) && !Self.isBound($0) })
        for (from, to) in zip(restOldText, restNewText) {
            result.text[to.id] = page.text[from.id]
        }
        let leftover = restOldText.dropFirst(restNewText.count)
        if !leftover.isEmpty, let last = readingOrder(newText.filter { result.text[$0.id] != nil && !Self.isBound($0) }).last {
            var target = result.text[last.id] ?? RichText()
            for box in leftover {
                target.paragraphs.append(contentsOf: page.text[box.id]?.paragraphs ?? [])
            }
            result.text[last.id] = target
        }

        // Images.
        let oldImages = old.imageBoxes.filter { page.images[$0.id] != nil }
        let newImages = new.imageBoxes
        var usedOldImages = Set<BoxID>()
        var usedNewImages = Set<BoxID>()
        for box in oldImages {
            guard let role = box.role,
                  let target = newImages.first(where: { $0.role == role && !usedNewImages.contains($0.id) })
            else { continue }
            result.images[target.id] = page.images[box.id]
            usedOldImages.insert(box.id)
            usedNewImages.insert(target.id)
        }
        let restOldImages = readingOrder(oldImages.filter { !usedOldImages.contains($0.id) })
        let restNewImages = readingOrder(newImages.filter { !usedNewImages.contains($0.id) })
        for (from, to) in zip(restOldImages, restNewImages) {
            result.images[to.id] = page.images[from.id]
        }

        let unassigned = newImages.filter { result.images[$0.id] == nil }.map(\.id)
        return Result(page: result, unassignedImageBoxes: unassigned)
    }
}
