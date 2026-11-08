import BBAI
import BBAICore
import BBModel
import BBStore
import Foundation

/// Plain-language lines for provider errors (A §7.11; the full `RefusalAdvisor` is Phase 9).
/// Provider wording is never shown here.
public enum ProviderErrorText {
    public static func message(for error: ProviderError) -> String {
        switch error {
        case .offline:
            "Offline — check your internet connection, then try again."
        case .missingKey:
            "Add your OpenAI key in Settings ▸ API Keys."
        case .invalidKey:
            "OpenAI didn't accept the key. Add your OpenAI key in Settings ▸ API Keys."
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
        case .readOnly: "This book is open read-only, so changes can't be saved."
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

    /// `0:07 of about 0:14`, or just `0:07` when the typical duration is unknown.
    public static func progress(elapsed: TimeInterval, typical: Double?) -> String {
        guard let typical, typical > 0 else { return clock(elapsed) }
        return "\(clock(elapsed)) of about \(clock(typical))"
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
    ///   - typical: typical seconds for an intent's model and quality.
    ///   - deliveryFailures: pictures that couldn't be saved, by message.
    public static func resolve(_ message: Message, snapshot: QueueSnapshot, pendingThisLaunch: Set<QueueItemID>,
                               deliveryFailures: [MessageID: String] = [:],
                               typical: (GenerationIntent) -> Double?) -> MessageStatus {
        if let itemID = message.queueItemID {
            if let entry = snapshot.entry(for: itemID) {
                switch entry.state {
                case .waiting: return .waiting
                case let .running(startedAt, _): return .running(startedAt: startedAt, typicalSeconds: typical(entry.item.intent))
                case let .failed(error): return .failed(error)
                }
            }
            return pendingThisLaunch.contains(itemID) ? .waiting : .interrupted
        }
        if message.producedVersion == nil, let text = deliveryFailures[message.id] { return .notSaved(text) }
        if let entry = snapshot.entries.first(where: { $0.item.messageID == message.id }),
           case let .failed(error) = entry.state {
            return .failed(error)
        }
        if let produced = message.producedVersion { return .produced(produced) }
        return .none
    }
}
