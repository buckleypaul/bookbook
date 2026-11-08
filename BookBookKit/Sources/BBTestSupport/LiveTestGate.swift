import Foundation

/// Decides whether live provider tests may run (implementation-plan.md §2.2, §2.3).
///
/// Live tests run only when `BOOKBOOK_LIVE_TESTS=1` **and** the provider's key variable is
/// present and non-empty. The key itself is never returned or stored here: callers that
/// need it read `ProcessInfo.processInfo.environment` directly and pass it straight to the
/// HTTP client. Never put the key, or anything derived from it, in a test message.
public enum LiveTestGate {
    public enum Provider: String, Sendable, CaseIterable {
        case openai
        case gemini

        /// The environment variable `scripts/live-tests.sh` inlines the key into.
        public var keyVariable: String {
            switch self {
            case .openai: "OPENAI_API_KEY"
            case .gemini: "GEMINI_API_KEY"
            }
        }
    }

    public static let enableVariable = "BOOKBOOK_LIVE_TESTS"

    /// `true` only when live tests are switched on and a key for `provider` is present.
    public static func isEnabled(
        for provider: Provider,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard environment[enableVariable] == "1" else { return false }
        guard let key = environment[provider.keyVariable], !key.isEmpty else { return false }
        return true
    }

    /// A human-readable reason for skipping, safe to print (it never contains the key).
    public static func skipReason(
        for provider: Provider,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        if environment[enableVariable] != "1" {
            return "Live tests are off: set \(enableVariable)=1 via scripts/live-tests.sh."
        }
        if (environment[provider.keyVariable] ?? "").isEmpty {
            return "Live tests are on but \(provider.keyVariable) is not set."
        }
        return nil
    }
}
