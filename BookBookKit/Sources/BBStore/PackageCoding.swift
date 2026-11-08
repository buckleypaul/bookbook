import BBModel
import Foundation

/// JSON coding and small file helpers shared by the store (A §5.1).
enum PackageCoding {
    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        e.dateEncodingStrategy = .custom(encodeDate)
        return e
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom(decodeDate)
        return d
    }

    // MARK: Dates
    //
    // ISO 8601 UTC with nine fractional digits ("2026-11-08T12:34:56.123456789Z"), diffable and
    // exact: the whole second comes from the ISO formatter and the fraction is written to 1 ns,
    // far finer than a Date's Double resolution (~1e-7 s), so `Date` round-trips unchanged.
    // Decoding also accepts dates without a fraction.

    @Sendable static func encodeDate(_ date: Date, _ encoder: any Encoder) throws {
        var whole = date.timeIntervalSinceReferenceDate.rounded(.down)
        var nanos = Int(((date.timeIntervalSinceReferenceDate - whole) * 1e9).rounded())
        if nanos >= 1_000_000_000 { whole += 1; nanos = 0 }
        let base = Date(timeIntervalSinceReferenceDate: whole).formatted(Date.ISO8601FormatStyle())
        let digits = String(nanos)
        let string = base.dropLast() + "." + String(repeating: "0", count: 9 - digits.count) + digits + "Z"
        var container = encoder.singleValueContainer()
        try container.encode(String(string))
    }

    @Sendable static func decodeDate(_ decoder: any Decoder) throws -> Date {
        let string = try decoder.singleValueContainer().decode(String.self)
        var main = Substring(string)
        var fraction = 0.0
        if let dot = string.firstIndex(of: ".") {
            let after = string.index(after: dot)
            let digitsEnd = string[after...].firstIndex { !$0.isNumber } ?? string.endIndex
            guard let n = Double("0." + string[after..<digitsEnd]) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad date \(string)"))
            }
            fraction = n
            main = string[..<dot] + string[digitsEnd...]
        }
        guard let whole = try? Date.ISO8601FormatStyle().parse(String(main)) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad date \(string)"))
        }
        return Date(timeIntervalSinceReferenceDate: whole.timeIntervalSinceReferenceDate + fraction)
    }

    static func encode<T: Encodable>(_ value: T) throws(StoreError) -> Data {
        do { return try encoder().encode(value) } catch { throw StoreError.corrupt("encode: \(error)") }
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data, what: String) throws(StoreError) -> T {
        do { return try decoder().decode(type, from: data) } catch { throw StoreError.corrupt("\(what): \(error)") }
    }

    /// Runs `body`, mapping any non-`StoreError` to `.io`.
    @discardableResult
    static func io<T>(_ what: String, _ body: () throws -> T) throws(StoreError) -> T {
        do { return try body() } catch let e as StoreError { throw e } catch { throw StoreError.io("\(what): \(error)") }
    }

    // MARK: Relative paths of entities

    static let bookPath = "book.json"
    static let stylePath = "style.json"
    static func templatePath(_ id: TemplateID) -> String { "templates/\(id.rawValue.uuidString).json" }
    static func pagePath(_ id: PageID) -> String { "pages/\(id.rawValue.uuidString).json" }
    static func sessionPath(_ id: SessionID) -> String { "sessions/\(id.rawValue.uuidString).json" }

    /// Encoded files for the dirty entities of `content`, keyed by relative path.
    static func files(for content: BookContent, dirty: DirtySet) throws(StoreError) -> [String: Data] {
        var out: [String: Data] = [:]
        if dirty.book { out[bookPath] = try encode(content.book) }
        if dirty.style { out[stylePath] = try encode(content.style) }
        for id in dirty.templates {
            guard let t = content.templates[id] else { throw StoreError.notFound("template \(id)") }
            out[templatePath(id)] = try encode(t)
        }
        for id in dirty.pages {
            guard let p = content.pages[id] else { throw StoreError.notFound("page \(id)") }
            out[pagePath(id)] = try encode(p)
        }
        for id in dirty.sessions {
            guard let s = content.sessions[id] else { throw StoreError.notFound("session \(id)") }
            out[sessionPath(id)] = try encode(s)
        }
        return out
    }

    // MARK: Durable file helpers

    static func writeSynced(_ data: Data, to url: URL) throws {
        try data.write(to: url)
        try fsync(url)
    }

    static func fsync(_ url: URL) throws {
        let fd = open(url.path(percentEncoded: false), O_RDONLY)
        guard fd >= 0 else { throw CocoaError(.fileReadNoPermission) }
        defer { close(fd) }
        _ = fcntl(fd, F_FULLFSYNC)
    }

    /// `rename(2)`: atomic, replaces an existing target.
    static func rename(_ from: URL, to: URL) throws {
        let r = Darwin.rename(from.path(percentEncoded: false), to.path(percentEncoded: false))
        guard r == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))])
        }
    }
}
