import BBModel
import Darwin
import Foundation
import Synchronization
import Testing
@testable import BBStore

/// Many contenders racing to take over the same stale `.lock`: exactly one may win (A §5.3).
@Suite(.cheapSync) struct LockTakeoverTests {
    private static let contenders = 16
    private static let rounds = 25

    /// A PID with no process right now (found with `kill(pid, 0)`; nothing is spawned).
    private func deadPID() throws -> Int32 {
        for pid in stride(from: Int32(99_998), to: 50_000, by: -1) where kill(pid, 0) == -1 && errno == ESRCH {
            return pid
        }
        throw CocoaError(.featureUnsupported)
    }

    private func plantStaleLock(in url: URL) throws {
        let stale = LockOwner(pid: try deadPID(), host: BookLock.currentHost, acquiredAt: testNow)
        try PackageCoding.encoder().encode(stale).write(to: url.appending(path: BookLock.fileName))
    }

    /// Runs `contenders` acquires at once on separate threads; returns their outcomes.
    private func race(_ url: URL, identity: @escaping @Sendable (Int) -> LockOwner) -> [Result<BookLock.Outcome, any Error>] {
        let results = Mutex<[Result<BookLock.Outcome, any Error>]>([])
        DispatchQueue.concurrentPerform(iterations: Self.contenders) { i in
            let result = Result { try BookLock(packageURL: url).acquire(as: identity(i)) }
            results.withLock { $0.append(result) }
        }
        return results.withLock { $0 }
    }

    /// Simulated separate processes (each a different host, so each sees the others as live).
    @Test func staleTakeover_separateOwners_exactlyOneWins() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        for round in 0..<Self.rounds {
            let url = dir.appending(path: "B\(round).bookbook")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try plantStaleLock(in: url)
            let outcomes = try race(url) { i in
                LockOwner(pid: getpid(), host: "contender-\(i)", acquiredAt: testNow)
            }.map { try $0.get() }
            let winners = outcomes.compactMap { if case let .wrote(owner) = $0 { owner } else { nil } }
            #expect(winners.count == 1, "round \(round): \(winners.count) winners")
            let onDisk = try PackageCoding.decoder().decode(LockOwner.self,
                                                            from: Data(contentsOf: url.appending(path: BookLock.fileName)))
            #expect(winners.first == onDisk)
            // Every loser was told the winner holds it.
            for outcome in outcomes where outcome != .wrote(onDisk) {
                #expect(outcome == .heldByOther(onDisk))
            }
            let names = try FileManager.default.contentsOfDirectory(atPath: url.path(percentEncoded: false))
            #expect(!names.contains { $0.hasPrefix(".lock.tmp") })
        }
    }

    /// Threads of this one process: one writes the lock, the rest find it re-entrant.
    @Test func staleTakeover_sameProcessThreads_exactlyOneWrites() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        for round in 0..<Self.rounds {
            let url = dir.appending(path: "B\(round).bookbook")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try plantStaleLock(in: url)
            let outcomes = try race(url) { _ in
                LockOwner(pid: BookLock.currentPID, host: BookLock.currentHost, acquiredAt: testNow)
            }.map { try $0.get() }
            let written = outcomes.filter { if case .wrote = $0 { true } else { false } }
            #expect(written.count == 1, "round \(round)")
            #expect(outcomes.filter { $0 == .reentrant }.count == Self.contenders - 1)
        }
    }

    /// An undecodable lock counts as stale; still exactly one contender takes it over.
    @Test func staleTakeover_garbageLock_exactlyOneWins() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "G.bookbook")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url.appending(path: BookLock.fileName))
        let outcomes = try race(url) { i in
            LockOwner(pid: getpid(), host: "contender-\(i)", acquiredAt: testNow)
        }.map { try $0.get() }
        #expect(outcomes.filter { if case .wrote = $0 { true } else { false } }.count == 1)
    }
}
