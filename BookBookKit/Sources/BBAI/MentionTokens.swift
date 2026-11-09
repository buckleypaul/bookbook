import BBModel
import Foundation

/// `⟦asset:<uuid>⟧` parsing for context assembly (A §4.3). Same format as `BBModel.MentionText`;
/// kept local so the assembler doesn't depend on the model lane's implementation details.
enum MentionTokens {
    private static let open = "⟦asset:"
    private static let close = "⟧"

    /// The text split into plain runs and mentioned IDs, in order.
    private enum Piece { case text(Substring), mention(AssetID) }

    private static func pieces(_ text: String) -> [Piece] {
        var out: [Piece] = []
        var rest = text[...]
        while let start = rest.range(of: open) {
            guard let end = rest.range(of: close, range: start.upperBound..<rest.endIndex),
                  let uuid = UUID(uuidString: String(rest[start.upperBound..<end.lowerBound])) else {
                // Not a well-formed token: keep the opening as plain text and continue after it.
                out.append(.text(rest[..<start.upperBound]))
                rest = rest[start.upperBound...]
                continue
            }
            out.append(.text(rest[..<start.lowerBound]))
            out.append(.mention(AssetID(rawValue: uuid)))
            rest = rest[end.upperBound...]
        }
        out.append(.text(rest))
        return out
    }

    /// Mentioned IDs in first-occurrence order, without duplicates.
    static func ids(in text: String) -> [AssetID] {
        var seen = Set<AssetID>()
        return pieces(text).compactMap { piece in
            if case let .mention(id) = piece, seen.insert(id).inserted { return id }
            return nil
        }
    }

    /// Tokens replaced by the asset's current name; unknown IDs become `fallback`.
    static func display(_ text: String, assets: [AssetID: Asset], fallback: String = "") -> String {
        pieces(text).map { piece in
            switch piece {
            case let .text(run): String(run)
            case let .mention(id): assets[id]?.name ?? fallback
            }
        }.joined()
    }
}
