import BBModel
import SwiftUI

/// Pure labels behind the where-used list and the delete confirmation (PD §8.3).
enum WhereUsedText {
    /// "Cover", or "Page N" in reading order.
    static func pageLabel(_ page: PageID, in content: BookContent) -> String {
        if page == content.book.coverPageID { return "Cover" }
        if let index = content.book.pageOrder.firstIndex(of: page) { return "Page \(index + 1)" }
        return "Page"
    }

    static func reasons(_ reasons: Set<UsageReason>) -> String {
        UsageReason.allCases.filter(reasons.contains).map {
            switch $0 {
            case .checklist: "in the page's asset list"
            case .mention: "mentioned in a prompt"
            case .placedImage: "used for the placed picture"
            }
        }.joined(separator: ", ")
    }

    /// "Page 3" for a page-level site, "Page 3, image box 2" for a box (numbered in layer order).
    static func siteLabel(_ site: UsageSite, in content: BookContent) -> String {
        let page = pageLabel(site.page, in: content)
        guard let box = site.box, let p = content.pages[site.page], let template = content.template(for: p)
        else { return page }
        let imageBoxes = template.imageBoxes
        guard let index = imageBoxes.firstIndex(where: { $0.id == box }) else { return page }
        return imageBoxes.count > 1 ? "\(page), image box \(index + 1)" : "\(page), image box"
    }

    /// One plain line for the delete confirmation.
    static func summary(_ sites: [UsageSite], in content: BookContent) -> String {
        guard !sites.isEmpty else { return "Not used on any page." }
        var labels: [String] = []
        for site in sites {
            let label = pageLabel(site.page, in: content)
            if !labels.contains(label) { labels.append(label) }
        }
        return "Used on \(labels.joined(separator: ", "))."
    }
}

/// The where-used list: one row per page (and box); clicking opens it in the page editor.
struct WhereUsedList: View {
    let sites: [UsageSite]
    let content: BookContent
    let onOpen: (PageID, BoxID?) -> Void

    var body: some View {
        if sites.isEmpty {
            Text("Not used on any page.").foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(sites, id: \.self) { site in
                    Button { onOpen(site.page, site.box) } label: {
                        HStack {
                            Image(systemName: site.box == nil ? "doc" : "photo")
                            Text(WhereUsedText.siteLabel(site, in: content))
                            Text(WhereUsedText.reasons(site.reasons)).foregroundStyle(.secondary)
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open \(WhereUsedText.siteLabel(site, in: content))")
                }
            }
        }
    }
}
