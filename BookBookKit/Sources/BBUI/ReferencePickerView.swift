import BBModel
import BBStore
import SwiftUI

/// "Reference another image…" (PD §8.6): pick a version from another box, page or asset
/// session to attach to the next request. Only that image is sent.
public enum ReferenceSources {
    public struct Source: Identifiable, Hashable, Sendable {
        public var owner: SessionOwner
        public var sessionID: SessionID
        public var label: String
        public var versions: [Version]
        public var id: SessionID { sessionID }
    }

    /// Every session with versions except `excluded`: the cover, story pages in reading order
    /// (boxes in template layer order), then assets by name.
    public static func list(in content: BookContent, excluding excluded: SessionID?) -> [Source] {
        var out: [Source] = []
        func add(_ owner: SessionOwner) {
            guard let id = BookMutations.sessionID(for: owner, in: content), id != excluded,
                  let session = content.sessions[id], !session.versions.isEmpty else { return }
            out.append(Source(owner: owner, sessionID: id, label: BookDocument.ownerLabel(owner, in: content),
                              versions: session.versions))
        }
        for pageID in content.pageIDsCoverFirst {
            guard let page = content.pages[pageID], let template = content.template(for: page) else { continue }
            for box in template.imageBoxes { add(.pageBox(pageID, box.id)) }
        }
        let assets = content.assets.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        for asset in assets { add(asset.owner) }
        return out
    }

    /// "Page 4 · Image 1 v2" for a chip; nil if the version is gone.
    public static func chipLabel(_ ref: VersionRef, in content: BookContent) -> String? {
        guard let session = content.sessions[ref.sessionID], let number = session.versionNumber(ref.versionID)
        else { return nil }
        return "\(BookDocument.ownerLabel(session.owner, in: content)) v\(number)"
    }
}

struct ReferencePickerView: View {
    let content: BookContent
    let store: BookStore
    let excluding: SessionID?
    let onPick: (VersionRef) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let sources = ReferenceSources.list(in: content, excluding: excluding)
        VStack(alignment: .leading, spacing: 0) {
            CrayonHeader("Reference Another Image", color: Crayon.sky)
                .padding()
            Text("Only the image you pick is sent with your next request: no conversation or other context comes with it.")
                .font(.caption).foregroundStyle(Crayon.inkSoft).padding(.horizontal)
                .padding(.bottom, 6)
            if sources.isEmpty {
                CrayonEmptyState("No Other Images", systemImage: "photo.on.rectangle", color: Crayon.sky,
                                 message: "Images from other boxes, pages and assets appear here.")
                    .frame(maxHeight: .infinity)
            } else {
                List(sources) { source in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(source.label).font(Crayon.font(.subheadline, weight: .bold)).foregroundStyle(Crayon.ink)
                        ScrollView(.horizontal) {
                            HStack(spacing: 10) {
                                ForEach(Array(source.versions.enumerated()), id: \.element.id) { index, version in
                                    Button {
                                        onPick(VersionRef(sessionID: source.sessionID, versionID: version.id))
                                        dismiss()
                                    } label: {
                                        VStack(spacing: 3) {
                                            VersionThumbnail(ref: version.image, url: store.imageURL(for: version.image))
                                                .frame(width: 64, height: 64)
                                                .clipShape(RoundedRectangle(cornerRadius: Crayon.thumbCornerRadius,
                                                                            style: .continuous))
                                            Text("v\(index + 1)").font(Crayon.font(.caption2, weight: .heavy))
                                                .foregroundStyle(Crayon.inkSoft)
                                        }
                                        .crayonCard(cornerRadius: Crayon.mediumCornerRadius, padding: 4)
                                        .crayonHover(tilt: index.isMultiple(of: 2) ? -2 : 2)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("\(source.label), version \(index + 1)")
                                }
                            }
                            // Room for the card shadows and the hover lift.
                            .padding(.horizontal, 4)
                            .padding(.top, 6)
                            .padding(.bottom, 10)
                        }
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(Color.clear)
                }
                .scrollContentBackground(.hidden)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                    .buttonBorderShape(.capsule)
            }
            .padding()
        }
        .frame(minWidth: 420, minHeight: 420)
        .crayonPaper()
    }
}
