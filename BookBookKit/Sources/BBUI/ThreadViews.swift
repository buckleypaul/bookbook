import BBModel
import SwiftUI

// What the session panels share (PD §8.6): the picture panel (`SessionPanel`), the text-style
// panel (`TextStylePanel`) and, for the bubbles, the Layouts chat (`TemplateChatPanel`).

/// The shape of a chat bubble in the session thread: rounded, with a small "tail" corner.
enum ThreadBubble {
    static let shape = UnevenRoundedRectangle(topLeadingRadius: Crayon.cornerRadius,
                                              bottomLeadingRadius: 4,
                                              bottomTrailingRadius: Crayon.cornerRadius,
                                              topTrailingRadius: Crayon.cornerRadius,
                                              style: .continuous)
}

/// The version a session panel has selected. Version details and refinement use `base`: the
/// selection while it exists, else the placed version.
struct SessionVersionSelection: Equatable {
    var selected: VersionID?
    /// The `resetEpoch` of a reset that kept versions; the placed version isn't the base while it matches.
    var freshEpoch: Int?

    /// The version Details and refinement use: the selection if it still exists, else the placed one.
    func base(in session: Session?, placed: VersionID?) -> VersionID? {
        guard let session else { return nil }
        if let selected, session.version(selected) != nil { return selected }
        // After Reset Session → Keep Versions the thread starts fresh (PD §8.6): no refining the placed
        // version until the user clicks one.
        if freshEpoch == session.resetEpoch { return nil }
        return placed.flatMap { session.version($0)?.id }
    }

    /// The version "Version details" shows: the base, else the newest.
    func detailsVersion(in session: Session, placed: VersionID?) -> Version? {
        (base(in: session, placed: placed) ?? session.versions.last?.id).flatMap { session.version($0) }
    }

    /// The user clicked a version.
    mutating func choose(_ id: VersionID) {
        selected = id
        freshEpoch = nil
    }

    /// An undo (or any other change) moved the placement: a stale selection would refine a
    /// version that isn't on the page.
    mutating func placedChanged() {
        selected = nil
        freshEpoch = nil
    }

    /// Call before deleting version `id`.
    mutating func deleted(_ id: VersionID) {
        if selected == id { selected = nil }
    }

    /// Call before resetting `session` (it's the session as it is before the reset).
    mutating func reset(keepVersions: Bool, session: Session?) {
        selected = nil
        freshEpoch = keepVersions ? session.map { $0.resetEpoch + 1 } : nil
    }
}

/// A session panel's title bar: the title and the "Session actions" menu.
struct SessionPanelHeader<MenuItems: View>: View {
    let title: String
    let color: Color
    @ViewBuilder let menuItems: MenuItems

    var body: some View {
        HStack(spacing: 8) {
            CrayonHeader(title, color: color)
            Spacer()
            Menu {
                menuItems
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(Crayon.inkSoft)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Session actions")
            .accessibilityLabel("Session actions")
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(Crayon.paperDeep)
    }
}

/// The dashed bubble an empty thread shows: a symbol and what to type.
struct ThreadIntroBubble: View {
    let text: String
    let systemImage: String
    let color: Color
    let fillOpacity: Double
    let rimOpacity: Double

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.title3.weight(.bold))
                .foregroundStyle(color)
                .accessibilityHidden(true)
            Text(text)
                .font(Crayon.font(.callout, weight: .medium))
                .foregroundStyle(Crayon.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(fillOpacity), in: ThreadBubble.shape)
        .overlay(ThreadBubble.shape.strokeBorder(color.opacity(rimOpacity),
                                                 style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
    }
}

extension View {
    /// A user message in a thread: selectable ink text on a wash of `color` with a rim.
    func threadBubble(_ color: Color, fillOpacity: Double, rimOpacity: Double) -> some View {
        foregroundStyle(Crayon.ink)
            .textSelection(.enabled)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(fillOpacity), in: ThreadBubble.shape)
            .overlay(ThreadBubble.shape.strokeBorder(color.opacity(rimOpacity), lineWidth: 1))
    }
}

/// The "Version details" disclosure: everything recorded about `version` (`VersionDetailsGrid`),
/// then the panel's own actions for it.
struct VersionDetailsDisclosure<Actions: View>: View {
    @Binding var isExpanded: Bool
    let version: Version
    let session: Session
    let bookID: BookID
    let assets: [AssetID: Asset]
    @ViewBuilder let actions: Actions

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VersionDetailsGrid(version: version, session: session, bookID: bookID, assets: assets)
            actions
        } label: {
            Text("Version details")
                .font(Crayon.font(.subheadline, weight: .bold))
                .foregroundStyle(Crayon.ink)
        }
        .padding(12)
        .background(Crayon.paperDeep,
                    in: RoundedRectangle(cornerRadius: Crayon.mediumCornerRadius, style: .continuous))
    }
}
