import Foundation
import Testing
@testable import BBTestSupport

/// Live tests must skip themselves unless BOOKBOOK_LIVE_TESTS=1 and a key are both present
/// (implementation-plan.md §2.2, Phase 1 "Tests added"). The key value used here is not
/// key-shaped, so the secret scan stays clean.
@Suite struct LiveTestGateTests {
    @Test(arguments: LiveTestGate.Provider.allCases)
    func skipsWhenEnableVariableMissing(_ provider: LiveTestGate.Provider) {
        let env = [provider.keyVariable: "placeholder"]
        #expect(!LiveTestGate.isEnabled(for: provider, environment: env))
        #expect(LiveTestGate.skipReason(for: provider, environment: env) != nil)
    }

    @Test(arguments: LiveTestGate.Provider.allCases)
    func skipsWhenEnableVariableIsNotOne(_ provider: LiveTestGate.Provider) {
        let env = [LiveTestGate.enableVariable: "true", provider.keyVariable: "placeholder"]
        #expect(!LiveTestGate.isEnabled(for: provider, environment: env))
    }

    @Test(arguments: LiveTestGate.Provider.allCases)
    func skipsWhenKeyMissingOrEmpty(_ provider: LiveTestGate.Provider) {
        #expect(!LiveTestGate.isEnabled(for: provider, environment: [LiveTestGate.enableVariable: "1"]))
        #expect(!LiveTestGate.isEnabled(for: provider, environment: [LiveTestGate.enableVariable: "1", provider.keyVariable: ""]))
    }

    @Test(arguments: LiveTestGate.Provider.allCases)
    func runsOnlyWithBoth(_ provider: LiveTestGate.Provider) {
        let env = [LiveTestGate.enableVariable: "1", provider.keyVariable: "placeholder"]
        #expect(LiveTestGate.isEnabled(for: provider, environment: env))
        #expect(LiveTestGate.skipReason(for: provider, environment: env) == nil)
    }

    @Test func skipReasonNeverContainsKey() {
        let env = [LiveTestGate.enableVariable: "1", "OPENAI_API_KEY": "placeholder-value"]
        let reason = LiveTestGate.skipReason(for: .gemini, environment: env) ?? ""
        #expect(!reason.contains("placeholder-value"))
    }

    /// In CI (and any normal `swift test`), the gate is closed.
    @Test func closedInThisProcessUnlessOptedIn() {
        let env = ProcessInfo.processInfo.environment
        if env[LiveTestGate.enableVariable] != "1" {
            #expect(!LiveTestGate.isEnabled(for: .openai))
            #expect(!LiveTestGate.isEnabled(for: .gemini))
        }
    }
}
