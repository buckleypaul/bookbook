import BBModel
import Foundation

// The session panel's pure helpers and small types (PD §8.6), kept apart from its view.

/// The availability text for "Edit Region…" (PD §8.6: unavailable, with a short explanation).
enum RegionEditEntry {
    static func unavailableMessage(isEditable: Bool, isOnline: Bool, hasKey: Bool,
                                   refusal: RegionEditRefusal?) -> String? {
        if !isEditable { return RegionEditRefusal.readOnly.message }
        if let refusal { return refusal.message }
        return UnavailableText.blocker(isEditable: isEditable, isOnline: isOnline, hasKey: hasKey)
    }
}

/// Which request a cost confirmation guards, so its button names the action (not always "Generate").
enum CostConfirmKind: Equatable {
    case generate, regionEdit, fixConsistency, checkConsistency, textStyle, repaint

    var buttonTitle: String {
        switch self {
        case .generate: "Generate"
        case .regionEdit: "Edit Region"
        case .fixConsistency: "Fix"
        case .checkConsistency: "Check"
        case .textStyle: "Style"
        case .repaint: "Repaint"
        }
    }

    /// The cost alert's closing question, without its "?" (`CostText.requestAlert`).
    var question: String {
        switch self {
        case .generate: "Generate this picture"
        case .regionEdit: "Edit this region"
        case .fixConsistency: "Fix this picture"
        case .checkConsistency: "Check this picture"
        case .textStyle: "Style this text"
        case .repaint: "Repaint this decoration"
        }
    }
}

extension SessionPanel {
    /// The panel's title: the box it's for, as the Queue window names it ("Image", "Image 2",
    /// "Cover Image"). The number is left out when the page has one image box.
    static func headerTitle(page pageID: PageID, box boxID: BoxID, in content: BookContent) -> String {
        let display = DraftAllPlanner.display(page: pageID, box: boxID, in: content)
        let count = content.pages[pageID].flatMap { content.template(for: $0) }?.imageBoxes.count ?? 0
        let box = count > 1 ? display.boxLabel : "Image"
        return pageID == content.book.coverPageID ? "Cover \(box)" : box
    }
}

/// The panel's pure lookups (testable without a view).
enum SessionPanelState {
    /// The owner's session. An asset whose session file is missing (a legacy book) gets an
    /// empty stand-in, so the panel shows its composer; the first message or import creates
    /// the real one. Nil when the box or asset is gone.
    static func session(for owner: SessionOwner, in content: BookContent) -> Session? {
        guard let id = BookMutations.sessionID(for: owner, in: content) else { return nil }
        if let session = content.sessions[id] { return session }
        return owner.assetID == nil ? nil : Session(id: id, owner: owner)
    }

    /// The Delete Version dialog's title: "Delete version 2?".
    static func deleteTitle(_ pending: VersionID?, in session: Session?) -> String {
        let number = pending.flatMap { id in session?.versionNumber(id) }
        return number.map { "Delete version \($0)?" } ?? "Delete this version?"
    }

    /// The placed version (page boxes) or the asset's chosen image.
    static func placedVersion(for owner: SessionOwner, in content: BookContent) -> VersionID? {
        switch owner {
        case let .pageBox(page, box): content.pages[page]?.images[box]?.placement?.versionID
        case let .asset(asset): content.assets[asset]?.chosen
        case let .textBox(page, box): content.pages[page]?.textStyles[box]?.versionID
        }
    }
}
