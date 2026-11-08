import Foundation
import Synchronization

/// `<package>/.lock`: JSON-encoded `LockOwner` naming the process that has the book open (A §5.3).
/// Not content: never journaled, swept or read as part of the book.
struct BookLock {
    static let fileName = ".lock"

    let url: URL

    init(packageURL: URL) {
        url = packageURL.appending(path: Self.fileName, directoryHint: .notDirectory)
    }

    /// This machine's host name, from `gethostname(3)` (`ProcessInfo.hostName` can block on DNS).
    static let currentHost: String = {
        var buf = [CChar](repeating: 0, count: 256)
        guard gethostname(&buf, buf.count) == 0 else { return "localhost" }
        buf[buf.count - 1] = 0
        return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }()

    static var currentPID: Int32 { getpid() }

    static func isCurrentProcess(_ owner: LockOwner) -> Bool {
        owner.host == currentHost && owner.pid == currentPID
    }

    /// A lock from another host is assumed live (its PID means nothing here). On this host it is
    /// stale only if `kill(pid, 0)` reports no such process; `EPERM` means it exists.
    static func isLive(_ owner: LockOwner) -> Bool {
        guard owner.host == currentHost else { return true }
        guard owner.pid > 0 else { return false }
        if kill(owner.pid, 0) == 0 { return true }
        return errno != ESRCH
    }

    /// The recorded owner; nil if there is no lock file. An unreadable or undecodable file reads
    /// as a stale lock (owner nil, `exists` true). The file is opened once and read through that
    /// descriptor, so a lock removed meanwhile reads as missing (`ENOENT`), never as garbage.
    func read() -> (exists: Bool, owner: LockOwner?) {
        let fd = open(url.path(percentEncoded: false), O_RDONLY | O_CLOEXEC)
        if fd < 0 { return (errno != ENOENT, nil) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard let data = try? handle.readToEnd() else { return (true, nil) }
        return (true, try? PackageCoding.decoder().decode(LockOwner.self, from: data))
    }

    enum Outcome: Equatable {
        /// This store wrote the lock file and owns it.
        case wrote(LockOwner)
        /// The file already names this process (re-entrant); this store does not own the file.
        case reentrant
        case heldByOther(LockOwner)
    }

    func acquire(now: Date = Date()) throws -> Outcome {
        try acquire(as: LockOwner(pid: Self.currentPID, host: Self.currentHost, acquiredAt: now))
    }

    /// `mine` names the acquiring process. Tests pass other identities to stand in for separate
    /// processes; the app always uses this process's.
    func acquire(as mine: LockOwner) throws -> Outcome {
        let isMine = { (owner: LockOwner) in owner.host == mine.host && owner.pid == mine.pid }
        // Another round runs only after losing a create or takeover race (the file was stale, or
        // vanished between checks), so this bound is reached only under heavy churn.
        for _ in 0..<100 {
            let current = read()
            if let owner = current.owner {
                if isMine(owner) { return .reentrant }
                if Self.isLive(owner) { return .heldByOther(owner) }
            }
            if current.exists {
                // Stale (dead PID on this host, or garbage): take it over, one contender at a time.
                if try takeOverStale(with: mine) { return .wrote(mine) }
                continue
            }
            if try write(mine, exclusive: true) { return .wrote(mine) }
        }
        guard let owner = read().owner else { throw Self.posixError(EAGAIN) }
        return isMine(owner) ? .reentrant : .heldByOther(owner)
    }

    /// Replaces a stale lock with `mine` while holding `flock(2)` on the package folder, so two
    /// contenders that both saw the same stale lock can't both win: under the flock it re-reads
    /// the file and replaces it only if it still exists and is still stale (a contender that won
    /// first has left a live lock). Returns false if not, and the caller re-checks.
    /// `link(2)` can't succeed while any lock file exists, and releases take the same flock, so
    /// nothing changes the file between the re-read and the replace.
    private func takeOverStale(with mine: LockOwner) throws -> Bool {
        try withTakeoverLock {
            let current = read()
            guard current.exists else { return false }
            if let owner = current.owner, Self.isLive(owner) || owner.host == mine.host && owner.pid == mine.pid {
                return false
            }
            try write(mine, exclusive: false)
            return true
        }
    }

    /// Runs `body` holding `flock(2)` on the package folder (takeovers and releases).
    private func withTakeoverLock<T>(_ body: () throws -> T) throws -> T {
        let dir = url.deletingLastPathComponent().path(percentEncoded: false)
        let fd = open(dir, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw Self.posixError(errno) }
        defer { close(fd) }
        while flock(fd, LOCK_EX) != 0 {
            guard errno == EINTR else { throw Self.posixError(errno) }
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    private static func posixError(_ code: Int32) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code),
                userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(code))])
    }

    /// Writes `owner` to a temp file, then either `link(2)`s it into place (exclusive: fails with
    /// false if a lock already exists) or `rename(2)`s over the old lock.
    @discardableResult
    func write(_ owner: LockOwner, exclusive: Bool) throws -> Bool {
        let tmp = url.deletingLastPathComponent().appending(path: ".lock.tmp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try PackageCoding.writeSynced(PackageCoding.encoder().encode(owner), to: tmp)
        if exclusive {
            if link(tmp.path(percentEncoded: false), url.path(percentEncoded: false)) == 0 { return true }
            if errno == EEXIST { return false }
            throw Self.posixError(errno)
        }
        try PackageCoding.rename(tmp, to: url)
        return true
    }

    /// Removes the lock file if it still names `owner`'s process (same host and PID), under the
    /// takeover flock.
    func release(_ owner: LockOwner) {
        _ = try? withTakeoverLock {
            guard let current = read().owner, current.host == owner.host, current.pid == owner.pid else { return }
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: Holders in this process

    /// How many `BookStore`s in this process hold each package's lock (by standardized path).
    /// Acquire-and-count and uncount-and-remove run under this mutex, so the file is removed only
    /// when the last holder in this process releases: a store that found the lock re-entrant
    /// never loses it to another store's release, and never removes it for the others.
    private static let holders = Mutex<[String: Int]>([:])

    private var holderKey: String { url.standardizedFileURL.path(percentEncoded: false) }

    /// `acquire()` for a `BookStore`: on `.wrote` or `.reentrant`, counts one more holder.
    func acquireHold(now: Date = Date()) throws -> Outcome {
        try Self.holders.withLock { holders throws -> Outcome in
            let outcome = try acquire(now: now)
            if case .heldByOther = outcome { return outcome }
            holders[holderKey, default: 0] += 1
            return outcome
        }
    }

    /// Drops one holder; the last one removes the file if it still names this process.
    func releaseHold() {
        Self.holders.withLock { holders in
            let count = (holders[holderKey] ?? 1) - 1
            holders[holderKey] = count > 0 ? count : nil
            if count <= 0 {
                release(LockOwner(pid: Self.currentPID, host: Self.currentHost, acquiredAt: Date()))
            }
        }
    }
}
