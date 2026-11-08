import Foundation

/// A type-safe identifier wrapping a `UUID` (architecture.md §4.1).
///
/// Encodes as a bare UUID string, and as a string key when used as a dictionary key
/// (so `[BoxID: RichText]` becomes a JSON object, not an array of pairs).
public struct TypedID<Tag>: Hashable, Codable, Sendable, CodingKeyRepresentable, CustomStringConvertible {
    public var rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    /// For fixed IDs in presets and tests. Traps on a malformed string.
    public init(_ uuidString: String) {
        guard let uuid = UUID(uuidString: uuidString) else { preconditionFailure("bad UUID literal") }
        self.rawValue = uuid
    }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(UUID.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var codingKey: any CodingKey { IDKey(stringValue: rawValue.uuidString) }

    public init?<T: CodingKey>(codingKey: T) {
        guard let uuid = UUID(uuidString: codingKey.stringValue) else { return nil }
        rawValue = uuid
    }

    public var description: String { rawValue.uuidString }
}

private struct IDKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

public enum BookTag {}
public enum PageTag {}
public enum BoxTag {}
public enum AssetTag {}
public enum SessionTag {}
public enum VersionTag {}
public enum TemplateTag {}
public enum MessageTag {}
public enum QueueItemTag {}
public enum CostRecordTag {}

public typealias BookID = TypedID<BookTag>
public typealias PageID = TypedID<PageTag>
public typealias BoxID = TypedID<BoxTag>
public typealias AssetID = TypedID<AssetTag>
public typealias SessionID = TypedID<SessionTag>
public typealias VersionID = TypedID<VersionTag>
public typealias TemplateID = TypedID<TemplateTag>
public typealias MessageID = TypedID<MessageTag>
public typealias QueueItemID = TypedID<QueueItemTag>
public typealias CostRecordID = TypedID<CostRecordTag>
