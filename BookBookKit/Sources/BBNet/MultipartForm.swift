import Foundation

/// `multipart/form-data` encoder. Unused by the Phase 2 slice; edits (Phase 8) upload with it.
public struct MultipartForm: Sendable {
    private let boundary: String
    private var parts = Data()

    public init(boundary: String = "bookbook-\(UUID().uuidString)") { self.boundary = boundary }

    private static func quoted(_ text: String) -> String {
        text.replacingOccurrences(of: "\"", with: "%22")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
    }

    public mutating func addField(name: String, value: String) {
        parts.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(Self.quoted(name))\"\r\n\r\n\(value)\r\n".utf8))
    }

    public mutating func addFile(name: String, filename: String, mimeType: String, data: Data) {
        parts.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(Self.quoted(name))\"; filename=\"\(Self.quoted(filename))\"\r\nContent-Type: \(mimeType)\r\n\r\n".utf8))
        parts.append(data)
        parts.append(Data("\r\n".utf8))
    }

    /// `contentType` is `multipart/form-data; boundary=…`.
    public func encoded() -> (contentType: String, body: Data) {
        var body = parts
        body.append(Data("--\(boundary)--\r\n".utf8))
        return ("multipart/form-data; boundary=\(boundary)", body)
    }
}
