import BBModel
import BBStore
import Foundation

/// A row in the book window's page list.
public struct PageListItem: Hashable, Sendable, Identifiable {
    public var id: PageID
    public var number: Int
    public var status: PageStatus

    public var title: String { "Page \(number)" }

    public var statusText: String {
        switch status {
        case .empty: "Empty"
        case .inProgress: "In progress"
        case .done: "Done"
        }
    }
}

/// Pure helpers behind the page list's selection, add and delete.
public enum PageListing {
    public static func items(_ content: BookContent) -> [PageListItem] {
        content.storyPages.enumerated().map { index, page in
            PageListItem(id: page.id, number: index + 1, status: content.status(of: page))
        }
    }

    /// The template for a new story page: an existing story page's, else the bundled story
    /// preset if the book has it, else any single-page template in the book.
    public static func storyTemplateID(in content: BookContent,
                                       preset: () -> TemplateID? = { try? Presets.storyTemplate().id }) -> TemplateID? {
        if let id = content.storyPages.first?.templateID, content.templates[id] != nil { return id }
        if let id = preset(), content.templates[id]?.kind == .single { return id }
        return content.templates.values.filter { $0.kind == .single }.map(\.id).min { $0.rawValue.uuidString < $1.rawValue.uuidString }
    }

    /// Index in `pageOrder` for a page added after `selection` (at the end with no selection).
    public static func insertionIndex(after selection: PageID?, in content: BookContent) -> Int {
        let order = content.book.pageOrder
        guard let selection, let index = order.firstIndex(of: selection) else { return order.count }
        return index + 1
    }

    /// What to select after deleting `pageID`: the next page, else the previous, else nil.
    public static func selectionAfterDeleting(_ pageID: PageID, in content: BookContent) -> PageID? {
        let order = content.book.pageOrder
        guard let index = order.firstIndex(of: pageID) else { return order.first }
        if index + 1 < order.count { return order[index + 1] }
        return index > 0 ? order[index - 1] : nil
    }
}
