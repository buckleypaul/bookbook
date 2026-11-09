import Foundation

/// `<package>/costs.jsonl`: an append-only ledger, one JSON object per line (A §5.1, §5.2).
/// The record type comes in Phase 9.
public struct CostLedger: Sendable {
    public let fileURL: URL

    public init(packageURL: URL) {
        fileURL = packageURL.appending(path: "costs.jsonl", directoryHint: .notDirectory)
    }

    /// Appends one record as a single line with `O_APPEND`, then fsyncs. Creates the file if needed.
    /// A truncated tail left by a crash is cut off first so the new record starts on its own line.
    public func append<Record: Encodable>(_ record: Record) throws(StoreError) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom(PackageCoding.encodeDate)
        var line: Data
        do { line = try encoder.encode(record) } catch { throw StoreError.corrupt("encode ledger record: \(error)") }
        // Compact JSON escapes newlines inside strings, so this only guards against a bad encoder.
        guard !line.contains(0x0A) else { throw StoreError.corrupt("ledger record contains a newline") }
        line.append(0x0A)
        try repair()
        try PackageCoding.io("append ledger") {
            let fd = open(fileURL.path(percentEncoded: false), O_WRONLY | O_APPEND | O_CREAT, 0o644)
            guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
            defer { close(fd) }
            let written = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            guard written == line.count else { throw CocoaError(.fileWriteUnknown) }
            _ = fcntl(fd, F_FULLFSYNC)
        }
    }

    /// Every complete line, decoded. A truncated or undecodable last line is skipped (not an error);
    /// a bad line anywhere else throws `.corrupt`. A missing file reads as empty.
    public func records<Record: Decodable>(_ type: Record.Type) throws(StoreError) -> [Record] {
        try decodeLines(Record.self) { (i, error) throws(StoreError) in
            throw StoreError.corrupt("costs.jsonl line \(i + 1): \(error)")
        }
    }

    /// Like `records`, but a bad line anywhere is skipped and counted instead of throwing, so
    /// one corrupt line doesn't hide the rest. The truncated tail is not counted.
    public func lenientRecords<Record: Decodable>(_ type: Record.Type) throws(StoreError)
        -> (records: [Record], skipped: Int) {
        var skipped = 0
        let out = try decodeLines(Record.self) { _, _ in skipped += 1 }
        return (out, skipped)
    }

    /// Decodes each non-empty line. An undecodable last line with no newline after it (a
    /// truncated tail) is skipped silently; any other bad line goes to `onBadLine` (0-based index),
    /// which throws or records it and lets the walk go on.
    private func decodeLines<Record: Decodable>(
        _ type: Record.Type, onBadLine: (Int, any Error) throws(StoreError) -> Void
    ) throws(StoreError) -> [Record] {
        guard let data = try readData() else { return [] }
        let decoder = PackageCoding.decoder()
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        let endsWithNewline = data.last == 0x0A
        var out: [Record] = []
        for (i, line) in lines.enumerated() {
            let isLast = i == lines.count - 1
            if isLast && endsWithNewline { break }  // the empty piece after the final newline
            if line.isEmpty { continue }
            do {
                out.append(try decoder.decode(Record.self, from: Data(line)))
            } catch {
                if isLast { break }  // truncated tail
                try onBadLine(i, error)
            }
        }
        return out
    }

    /// Cuts a truncated last line (no trailing newline) off the file. Returns true if it changed anything.
    @discardableResult
    public func repair() throws(StoreError) -> Bool {
        guard let data = try readData(), let last = data.last, last != 0x0A else { return false }
        let keep = data.lastIndex(of: 0x0A).map { data.distance(from: data.startIndex, to: $0) + 1 } ?? 0
        try PackageCoding.io("repair ledger") {
            let fd = open(fileURL.path(percentEncoded: false), O_WRONLY)
            guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
            defer { close(fd) }
            guard ftruncate(fd, off_t(keep)) == 0 else { throw CocoaError(.fileWriteUnknown) }
            _ = fcntl(fd, F_FULLFSYNC)
        }
        return true
    }

    private func readData() throws(StoreError) -> Data? {
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else { return nil }
        return try PackageCoding.io("read ledger") { try Data(contentsOf: fileURL) }
    }
}
