import BBModel
import SwiftUI

/// `@mention` autocomplete (PD §8.6, A §4.3): the pure part. The prompt field holds typed
/// text ("@Pip yawning"); a pick inserts the asset's exact name, and the send turns every
/// `@Name` into its token with `MentionText.tokenizing`, so picks and hand-typed names store
/// the same way.
public enum MentionCompletion {
    public struct Query: Equatable, Sendable {
        /// From the `@` to the end of the text.
        public var range: Range<String.Index>
        /// What follows the `@`.
        public var text: String
    }

    /// The `@…` being typed at the end of `text`: the last `@` that starts the text or follows
    /// a non-word character, with no line break after it and not ending in whitespace (a space
    /// after a complete name closes the completion). Nil when there is none.
    public static func activeQuery(in text: String) -> Query? {
        guard let at = text.lastIndex(of: "@") else { return nil }
        if at > text.startIndex {
            let before = text[text.index(before: at)]
            if before.isLetter || before.isNumber || before == "_" { return nil }
        }
        let query = String(text[text.index(after: at)...])
        guard !query.contains(where: \.isNewline), query.count <= 40,
              query.last.map({ !$0.isWhitespace }) ?? true else { return nil }
        return Query(range: at..<text.endIndex, text: query)
    }

    /// Assets whose name starts with the query (then those containing it), case- and
    /// diacritic-insensitive, by name; all assets for an empty query. At most `limit`.
    public static func suggestions(for query: String, assets: [Asset], limit: Int = 8) -> [Asset] {
        let sorted = assets.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        guard !query.isEmpty else { return Array(sorted.prefix(limit)) }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let prefix = sorted.filter { $0.name.range(of: query, options: options.union(.anchored)) != nil }
        let contains = sorted.filter { asset in
            !prefix.contains(where: { $0.id == asset.id }) && asset.name.range(of: query, options: options) != nil
        }
        return Array((prefix + contains).prefix(limit))
    }

    /// `text` with the query replaced by "@<name> ".
    public static func insert(_ asset: Asset, replacing query: Query, in text: String) -> String {
        String(text[..<query.range.lowerBound]) + "@" + asset.name + " "
    }
}

/// The suggestions list shown under the prompt field while an `@` query is active.
struct MentionSuggestions: View {
    let suggestions: [Asset]
    let onPick: (Asset) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(suggestions) { asset in
                Button {
                    onPick(asset)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: AssetTypeText.symbol(asset.type)).foregroundStyle(.secondary)
                        Text(asset.name)
                        Spacer()
                        Text(AssetTypeText.name(asset.type)).font(.caption).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Mention \(asset.name)")
            }
        }
        .padding(.vertical, 4)
        .background(.background, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
    }
}

/// Labels and symbols for asset types.
enum AssetTypeText {
    static func name(_ type: AssetType) -> String {
        switch type {
        case .character: "Character"
        case .place: "Place"
        case .object: "Object"
        }
    }

    static func symbol(_ type: AssetType) -> String {
        switch type {
        case .character: "person.crop.circle"
        case .place: "mountain.2"
        case .object: "cube"
        }
    }
}
