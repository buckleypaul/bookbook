import BBAI
import BBAICore
import BBModel
import BBStore
import Foundation

/// One wording per reason an AI or editing action is unavailable, so every panel says the same
/// thing (the Generate note, Edit Region…, Check Consistency, provider and store errors).
public enum UnavailableText {
    public static let noKey = "Add your OpenAI API key in Settings ▸ API Keys."
    public static let offline = "You're offline. AI requests need an internet connection."
    /// Read-only books are usually locked by another copy of BookBook (`LockAdviceText`), but
    /// not always, so this doesn't say why.
    public static let readOnly = "This book is open read-only, so it can't be changed."
}

/// Plain-language lines for provider errors (A §7.11; the full `RefusalAdvisor` is Phase 9).
/// Provider wording is never shown here.
public enum ProviderErrorText {
    public static func message(for error: ProviderError) -> String {
        switch error {
        case .offline:
            "Offline — check your internet connection, then try again."
        case .missingKey:
            UnavailableText.noKey
        case .invalidKey:
            "OpenAI didn't accept the key. Check your OpenAI API key in Settings ▸ API Keys."
        case .refused:
            "The request was blocked by the provider's safety system. Try rephrasing."
        case .verificationRequired:
            "Your OpenAI organization needs to be verified to use this model. Verify it on the OpenAI website, then try again."
        case .regionUnsupported:
            "The provider doesn't offer image generation in your region."
        case .billing:
            "Your OpenAI account is out of credit or over its spending limit. Check billing on the OpenAI website."
        case .rateLimited:
            "The provider is busy right now. Wait a minute, then try again."
        case .noImage where RegionEditFailure.isBlankArea(error):
            "The model returned a blank area instead of an edit. Try again, or select a slightly larger area."
        case .noImage:
            "The provider didn't send back an image. Try again."
        case let .invalidRequest(param, _):
            if let param { "The provider rejected the request (\(param)). Try again." }
            else { "The provider rejected the request. Try again." }
        case .modelUnavailable:
            "This model isn't available to your account right now."
        case .transient:
            "The provider had a temporary problem. Try again in a moment."
        case .timeout:
            "The request took too long and was stopped. Try again."
        case .cancelled:
            "Cancelled."
        case .unknown:
            "Something went wrong with the request. Try again."
        }
    }
}

/// What the locked-book screen and alert say besides the owner (#99b).
public enum LockAdviceText {
    public static func message(offersOpenAnyway: Bool) -> String {
        offersOpenAnyway
            ? "Another copy of BookBook is using it. You can open it read-only to look at it. If that copy has quit or crashed, you can open it anyway."
            : "Another copy of BookBook is using it. You can open it read-only to look at it, but you won't be able to change it."
    }
}

/// Plain-language lines for storage errors.
public enum StoreErrorText {
    public static func message(for error: StoreError) -> String {
        switch error {
        case .notFound: "The book couldn't be found. It may have been moved or deleted."
        case .corrupt: "The book's files couldn't be read."
        case .io: "The book couldn't be read or written. Check the disk has space."
        case .schemaTooNew: "This book was made with a newer version of BookBook."
        case .keychain: "The Keychain couldn't be updated."
        case .locked(let owner): "This book is open in BookBook on \(owner.host)."
        case .readOnly: UnavailableText.readOnly
        }
    }

    public static func message(for error: any Error) -> String {
        if let error = error as? StoreError { return message(for: error) }
        return error.localizedDescription
    }
}

/// Elapsed time against the model's typical duration (A §7.9: no real progress is reported).
public enum ElapsedTimeText {
    /// `m:ss`, e.g. `0:07`, `1:05`. Negative values count as zero.
    public static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return "\(total / 60):" + String(format: "%02d", total % 60)
    }

    /// `0:42 of ~1:10`; once past the typical duration `2:10 (usually ~1:10)`; just `0:42` when
    /// the typical duration is unknown. Used by the session thread, the Queue window and the
    /// sidebar badge.
    public static func progress(elapsed: TimeInterval, typical: Double?) -> String {
        guard let typical, typical > 0 else { return clock(elapsed) }
        let shown = clock(elapsed)
        if max(0, elapsed.rounded(.down)) > typical.rounded(.down) { return "\(shown) (usually ~\(clock(typical)))" }
        return "\(shown) of ~\(clock(typical))"
    }
}

/// What the session thread shows under a user message.
public enum MessageStatus: Hashable, Sendable {
    /// No request pending and nothing produced (e.g. an earlier failure from before a relaunch).
    case none
    case waiting
    case running(startedAt: Date, typicalSeconds: Double?)
    case failed(ProviderError)
    /// Pending in the book, but the in-memory queue (Phase 2) no longer has it: the app quit.
    case interrupted
    /// The picture arrived but couldn't be written into the book (plain-language reason).
    case notSaved(String)
    case produced(VersionID)

    /// - Parameters:
    ///   - pendingThisLaunch: queue items enqueued since launch (covers the moment before the
    ///     queue's first snapshot includes a new item).
    ///   - typical: typical seconds for a queue item (its model, and quality for pictures).
    ///   - deliveryFailures: pictures that couldn't be saved, by message.
    public static func resolve(_ message: Message, snapshot: QueueSnapshot, pendingThisLaunch: Set<QueueItemID>,
                               deliveryFailures: [MessageID: String] = [:],
                               typical: (QueueItem) -> Double?) -> MessageStatus {
        if let itemID = message.queueItemID {
            if let entry = snapshot.entry(for: itemID) {
                switch entry.state {
                case .waiting, .retrying: return .waiting
                case let .running(startedAt, _, _): return .running(startedAt: startedAt, typicalSeconds: typical(entry.item))
                case let .failed(failure): return .failed(failure.error)
                }
            }
            return pendingThisLaunch.contains(itemID) ? .waiting : .interrupted
        }
        if message.producedVersion == nil, let text = deliveryFailures[message.id] { return .notSaved(text) }
        if let entry = snapshot.entries.first(where: { $0.item.messageID == message.id }),
           case let .failed(failure) = entry.state {
            return .failed(failure.error)
        }
        if let produced = message.producedVersion { return .produced(produced) }
        return .none
    }
}
