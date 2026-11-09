import Foundation

/// Path strings used as keys and for prefix checks inside BBStore. Each drops trailing slashes
/// (keeping a lone "/") so a directory URL and a plain one give the same string.
enum CanonicalPath {
    /// The standardized path (`.` and `..` removed; symlinks untouched).
    static func standardized(_ url: URL) -> String {
        trimmed(url.standardizedFileURL.path(percentEncoded: false))
    }

    /// Foundation's symlink-resolved path (`resolvingSymlinksInPath`, which strips `/private`).
    static func symlinksResolved(_ url: URL) -> String {
        trimmed(url.resolvingSymlinksInPath().path(percentEncoded: false))
    }

    /// True if `child` resolves (following symlinks) to a path strictly inside `parent`.
    /// Used to refuse a package subfolder that is a symlink leading out of the package.
    static func isInside(_ child: URL, _ parent: URL) -> Bool {
        let parentPath = symlinksResolved(parent)
        return symlinksResolved(child).hasPrefix(parentPath == "/" ? "/" : parentPath + "/")
    }

    /// The `realpath(3)` canonical path (keeps `/private`, as FSEvents reports it), falling back
    /// to the standardized path if it can't be resolved (e.g. it doesn't exist).
    static func real(_ url: URL) -> String {
        guard let resolved = realpath(url.path(percentEncoded: false), nil) else { return standardized(url) }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func trimmed(_ path: String) -> String {
        var p = path
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p
    }
}
