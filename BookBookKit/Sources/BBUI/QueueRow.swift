import BBAI
import BBAICore
import BBModel
import Foundation

/// What one Queue row shows and allows, as pure data (A §6.1, §7.9).
public struct QueueRowModel: Equatable {
    public enum Action: Hashable { case remove, retry, cancel }

    public static let maxAttempts = 4

    public var title: String
    /// `Page 3 · Image 1`.
    public var location: String
    public var estimateText: String
    /// Waiting items can be dragged to reorder.
    public var canReorder: Bool
    public var actions: Set<Action>
    public var isFailed: Bool

    public init(entry: QueueEntry) {
        let d = entry.item.display
        title = d.bookTitle.isEmpty ? "Untitled" : d.bookTitle
        location = [d.pageLabel, d.boxLabel].filter { !$0.isEmpty }.joined(separator: " · ")
        estimateText = CostText.estimate(entry.item.estimate)
        switch entry.state {
        case .waiting:
            canReorder = true
            actions = [.remove]
            isFailed = false
        case .running:
            canReorder = false
            actions = [.cancel]
            isFailed = false
        case .retrying:
            canReorder = false
            actions = [.remove]
            isFailed = false
        case .failed:
            canReorder = false
            actions = [.remove, .retry]
            isFailed = true
        }
    }

    /// The state line. `typical` is the model's typical seconds; `headline` is the advice headline
    /// for a failed entry.
    public static func stateText(_ state: QueueItemState, now: Date, typical: Double?, headline: String?,
                                 isConsistencyCheck: Bool = false) -> String {
        switch state {
        case .waiting:
            return "Waiting"
        case let .running(startedAt, _, attempt):
            let time = ElapsedTimeText.progress(elapsed: now.timeIntervalSince(startedAt), typical: typical)
            let retry = attempt > 1 ? " (attempt \(attempt) of \(maxAttempts))" : ""
            return "\(isConsistencyCheck ? "Checking consistency…" : "Generating…") \(time)\(retry)"
        case let .retrying(attempt, resumesAt, _):
            let seconds = max(0, Int(resumesAt.timeIntervalSince(now).rounded(.up)))
            return "Retrying in \(seconds) s (attempt \(attempt) of \(maxAttempts))"
        case .failed:
            return headline ?? "Failed"
        }
    }
}

/// The pause banner, shared by the Queue window and the Library (A §7.9).
public struct QueueBannerModel: Equatable {
    public var text: String
    /// Whether a Resume button is offered (not while offline: it resumes itself).
    public var offersResume: Bool

    public init?(pause: QueuePause?) {
        switch pause {
        case nil:
            return nil
        case let .restored(count):
            text = count == 1 ? "Resume 1 queued request" : "Resume \(count) queued requests"
            offersResume = true
        case .offline:
            text = "Offline — queued requests will run when the network returns"
            offersResume = false
        case .user:
            text = "The queue is paused"
            offersResume = true
        }
    }
}

/// The sidebar badge: waiting, retrying plus running items app-wide.
public struct QueueBadgeModel: Equatable {
    public var count: Int
    public var running: QueueEntry?
    public var isPaused: Bool

    public init(snapshot: QueueSnapshot) {
        isPaused = snapshot.pause != nil
        let live = snapshot.entries.filter { if case .failed = $0.state { false } else { true } }
        count = live.count
        running = live.first { if case .running = $0.state { true } else { false } }
    }

    public var isHidden: Bool { count == 0 }
    public var title: String {
        (count == 1 ? "1 in queue" : "\(count) in queue") + (isPaused ? " (paused)" : "")
    }
}

public extension QueueSnapshot {
    var undeliveredText: String? {
        guard undeliveredCount > 0 else { return nil }
        return undeliveredCount == 1 ? "1 result waiting for a locked book"
            : "\(undeliveredCount) results waiting for a locked book"
    }
}
