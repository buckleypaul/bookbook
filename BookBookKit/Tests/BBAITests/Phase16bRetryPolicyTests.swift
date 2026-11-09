import BBAICore
import Testing
@testable import BBAI

@Suite struct Phase16bRetryPolicyTests {
    @Test func offlineWritesNoLedgerLine() {
        #expect(QueueLedgerRule.forFailure(.offline) == .none)
    }

    @Test func timeoutStillEstimates() {
        #expect(QueueLedgerRule.forFailure(.timeout) == .estimate(.failed))
    }
}
