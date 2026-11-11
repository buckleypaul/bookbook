/// Names suggested in save panels.
enum SafeFileName {
    /// `name` with `/` and `:` (path separators) replaced by `-`, or `fallback` when `name` is empty.
    static func make(_ name: String, fallback: String) -> String {
        guard !name.isEmpty else { return fallback }
        return name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }
}
