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

    /// This Mac's hardware UUID from `gethostuuid(2)` (#99b). Stable across host-name changes;
    /// nil if the call fails.
    static let currentHostID: String? = {
        var id = UUID().uuid
        var wait = timespec(tv_sec: 1, tv_nsec: 0)
        let result = withUnsafeMutableBytes(of: &id) { raw in
            gethostuuid(raw.baseAddress!.assumingMemoryBound(to: UInt8.self), &wait)
        }
        return result == 0 ? UUID(uuid: id).uuidString : nil
    }()

    static var currentPID: Int32 { getpid() }

    /// This process's identity, as written into `.lock`.
    static func currentOwner(acquiredAt: Date = Date()) -> LockOwner {
        LockOwner(pid: currentPID, host: currentHost, acquiredAt: acquiredAt, hostID: currentHostID)
    }

    /// Whether two owners name the same Mac: by `hostID` when both have one (a host-name change
    /// doesn't make this Mac's own crashed lock look foreign), else by host name (older locks).
    static func sameMachine(_ a: LockOwner, _ b: LockOwner) -> Bool {
        if let x = a.hostID, let y = b.hostID { return x == y }
        return a.host == b.host
    }

    /// Same machine and same PID.
    static func sameProcess(_ a: LockOwner, _ b: LockOwner) -> Bool {
        a.pid == b.pid && sameMachine(a, b)
    }

    static func isCurrentProcess(_ owner: LockOwner) -> Bool {
        sameProcess(owner, currentOwner())
    }

    /// Slack for comparing a process's start time with `acquiredAt` (JSON date rounding, clock skew).
    static let startTimeSlack: TimeInterval = 5

    /// A lock from another machine is assumed live (its PID means nothing here). On this machine
    /// it is stale if `kill(pid, 0)` reports no such process (`EPERM` means it exists), or if the
    /// process now using that PID started after the lock was taken (a reused PID, #99a).
    /// `startTime` returns a PID's start time (nil if unknown); tests inject it.
    static func isLive(_ owner: LockOwner,
                       startTime: (Int32) -> Date? = BookLock.processStartTime) -> Bool {
        guard sameMachine(owner, currentOwner()) else { return true }
        guard owner.pid > 0 else { return false }
        if kill(owner.pid, 0) != 0, errno == ESRCH { return false }
        if let started = startTime(owner.pid), started > owner.acquiredAt.addingTimeInterval(startTimeSlack) {
            return false
        }
        return true
    }

    /// The start time of `pid` from `sysctl(KERN_PROC_PID)` (`p_starttime`); nil if there is no
    /// such process or the call fails.
    @Sendable static func processStartTime(_ pid: Int32) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0,
              info.kp_proc.p_pid == pid else { return nil }
        let tv = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000)
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
        try acquire(as: Self.currentOwner(acquiredAt: now))
    }

    /// `mine` names the acquiring process. Tests pass other identities to stand in for separate
    /// processes; the app always uses this process's.
    func acquire(as mine: LockOwner) throws -> Outcome {
        let isMine = { (owner: LockOwner) in Self.sameProcess(owner, mine) }
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
            if let owner = current.owner, Self.isLive(owner) || Self.sameProcess(owner, mine) {
                return false
            }
            try write(mine, exclusive: false)
            return true
        }
    }

    enum TakeoverOutcome: Equatable {
        /// The lock now names `mine` (it named `expected`, or there was none).
        case tookOver(LockOwner)
        /// The file names someone other than `expected` now (it changed since the caller looked).
        case ownerChanged(LockOwner?)
    }

    /// Replaces a lock the user chose to override ("Open Anyway", #99b) with `mine`, but only if
    /// the file still names exactly `expected` (compared in full, `acquiredAt` included), under
    /// the takeover flock. A missing file is simply created. Use for locks `acquire` reports as
    /// held by other (another Mac's, which can never be proved stale from here).
    func takeOver(expected: LockOwner, as mine: LockOwner) throws -> TakeoverOutcome {
        try withTakeoverLock {
            let current = read()
            if current.exists {
                guard current.owner == expected else { return .ownerChanged(current.owner) }
                try write(mine, exclusive: false)
                return .tookOver(mine)
            }
            // Released meanwhile: create it (a release also takes this flock, so no one else can be mid-write,
            // but another acquirer can still `link` first).
            if try write(mine, exclusive: true) { return .tookOver(mine) }
            return .ownerChanged(read().owner)
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

    /// Removes the lock file if it still names `owner`'s process (same machine and PID), under the
    /// takeover flock.
    func release(_ owner: LockOwner) {
        _ = try? withTakeoverLock {
            guard let current = read().owner, Self.sameProcess(current, owner) else { return }
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: Holders in this process

    /// How many `BookStore`s in this process hold each package's lock (by the package's real path).
    /// Acquire-and-count and uncount-and-remove run under this mutex, so the file is removed only
    /// when the last holder in this process releases: a store that found the lock re-entrant
    /// never loses it to another store's release, and never removes it for the others.
    private static let holders = Mutex<[String: Int]>([:])

    /// The package folder's `realpath(3)` (so a symlinked and a direct URL share one count, #105b),
    /// falling back to the standardized path if it can't be resolved.
    var holderKey: String {
        CanonicalPath.real(url.deletingLastPathComponent())
    }

    /// `acquire()` for a `BookStore`: on `.wrote` or `.reentrant`, counts one more holder under
    /// `key` (the caller's `holderKey`, kept for `releaseHold(key:)`).
    /// `exclusiveInProcess`: also report `.heldByOther` (naming this process) when another store
    /// in this process already holds the lock, or the file already names this process, so a
    /// background job (duplicate-ID resolution) never works on a book this process has open or
    /// is opening or writing (#3b, #3c).
    func acquireHold(key: String, now: Date = Date(), exclusiveInProcess: Bool = false) throws -> Outcome {
        try Self.holders.withLock { holders throws -> Outcome in
            if exclusiveInProcess, (holders[key] ?? 0) > 0 {
                return .heldByOther(read().owner ?? Self.currentOwner(acquiredAt: now))
            }
            let outcome = try acquire(now: now)
            switch outcome {
            case .heldByOther:
                return outcome
            case .reentrant where exclusiveInProcess:
                return .heldByOther(read().owner ?? Self.currentOwner(acquiredAt: now))
            case .wrote, .reentrant:
                holders[key, default: 0] += 1
                return outcome
            }
        }
    }

    /// `takeOver(expected:as:)` for a `BookStore`, as this process: on success counts one holder
    /// under `key` (the caller's `holderKey`).
    func takeOverHold(key: String, expected: LockOwner, now: Date = Date()) throws -> TakeoverOutcome {
        try Self.holders.withLock { holders throws -> TakeoverOutcome in
            let outcome = try takeOver(expected: expected, as: Self.currentOwner(acquiredAt: now))
            if case .tookOver = outcome { holders[key, default: 0] += 1 }
            return outcome
        }
    }

    /// Whether any `BookStore` in this process holds this package's lock.
    var isHeldInProcess: Bool {
        let key = holderKey
        return Self.holders.withLock { ($0[key] ?? 0) > 0 }
    }

    /// Drops one holder from `key` (the `holderKey` taken at acquire); the last one removes the file if it still names this process.
    func releaseHold(key: String) {
        Self.holders.withLock { holders in
            let count = (holders[key] ?? 1) - 1
            holders[key] = count > 0 ? count : nil
            if count <= 0 {
                release(Self.currentOwner())
            }
        }
    }
}
