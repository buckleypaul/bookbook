import Foundation

// Phase 3 contract (main thread). The migrator/ledger lane implements it. The record type comes in Phase 9.

/// `<package>/costs.jsonl`: an append-only ledger, one JSON object per line (A §5.1, §5.2).
public struct CostLedger: Sendable {
    public let fileURL: URL

    public init(packageURL: URL) {
        fileURL = packageURL.appending(path: "costs.jsonl", directoryHint: .notDirectory)
    }

    /// Appends one record as a single line with `O_APPEND`, then fsyncs. Creates the file if needed.
    public func append<Record: Encodable>(_ record: Record) throws(StoreError) {}

    /// Every complete line, decoded. A truncated or undecodable last line is skipped (not an error);
    /// a bad line anywhere else throws `.corrupt`. A missing file reads as empty.
    public func records<Record: Decodable>(_ type: Record.Type) throws(StoreError) -> [Record] {
        []
    }

    /// Cuts a truncated last line (no trailing newline) off the file. Returns true if it changed anything.
    @discardableResult
    public func repair() throws(StoreError) -> Bool {
        false
    }
}
