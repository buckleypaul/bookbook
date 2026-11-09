import BBModel
import BBStore
import Foundation
import Testing
@testable import BBUI

@MainActor @Suite struct Phase16bAppShellTests {
    private func defaults(_ name: String = #function) -> UserDefaults {
        let suite = "phase16b.shell.\(name)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    // MARK: #4

    @Test func closingSetupWithoutButtonsStillMarksItCompleted() {
        let state = OnboardingState(defaults: defaults())
        let model = OnboardingModel(state: state)
        model.skipSetup() // what the view's onDisappear calls
        model.skipSetup() // idempotent
        #expect(state.isCompleted)
    }

    @Test func resetReturnsToFirstStep() {
        let model = OnboardingModel(state: OnboardingState(defaults: defaults()))
        model.next(); model.next()
        #expect(!model.isFirst)
        model.reset()
        #expect(model.isFirst)
    }

    @Test func automationLaunchArgumentsSuppressSetup() {
        let state = OnboardingState(defaults: defaults("state"))
        #expect(state.shouldShowOnLaunch(hasKey: false, underTests: false, arguments: defaults("a0")))
        let skip = defaults("a1"); skip.set(true, forKey: "BookBookSkipOnboarding")
        #expect(!state.shouldShowOnLaunch(hasKey: false, underTests: false, arguments: skip))
        let root = defaults("a2"); root.set("/tmp/x", forKey: "BookBookLibraryRoot")
        #expect(!state.shouldShowOnLaunch(hasKey: false, underTests: false, arguments: root))
    }

    // MARK: #67a

    @Test func pageNumberFontKeepsStoredFaceWhenUntouched() {
        #expect(PageNumbersSheet.resolvedFont(family: "Georgia", initialFamily: "Georgia", stored: "Georgia-Bold") == "Georgia-Bold")
        #expect(PageNumbersSheet.resolvedFont(family: nil, initialFamily: nil, stored: nil) == nil)
    }

    @Test func pageNumberFontChangesToBodyOrNewFamily() {
        #expect(PageNumbersSheet.resolvedFont(family: nil, initialFamily: "Georgia", stored: "Georgia-Bold") == nil)
        #expect(PageNumbersSheet.resolvedFont(family: "Helvetica", initialFamily: "Georgia", stored: "Georgia-Bold") != "Georgia-Bold")
        #expect(PageNumbersSheet.resolvedFont(family: "Not A Real Family", initialFamily: "Georgia", stored: "Georgia-Bold") == nil)
    }

    // MARK: #99b

    @Test func openAnywayOnlyForOtherMacs() {
        let other = LockOwner(pid: 1, host: "Other.local", acquiredAt: Date(), hostID: "AAAA")
        let sameID = LockOwner(pid: 1, host: "Renamed.local", acquiredAt: Date(), hostID: "BBBB")
        let legacySame = LockOwner(pid: 1, host: "Mine.local", acquiredAt: Date())
        let legacyOther = LockOwner(pid: 1, host: "Other.local", acquiredAt: Date())
        let mine = LockOwner(pid: 2, host: "Mine.local", acquiredAt: Date(), hostID: "BBBB")
        #expect(LockTakeOver.offersOpenAnyway(other, thisMachine: mine))
        #expect(!LockTakeOver.offersOpenAnyway(sameID, thisMachine: mine))
        #expect(!LockTakeOver.offersOpenAnyway(legacySame, thisMachine: mine))
        #expect(LockTakeOver.offersOpenAnyway(legacyOther, thisMachine: mine))
        #expect(!LockTakeOver.offersOpenAnyway(nil))
    }

    @Test func takeOverReplacesAForeignLock() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("L8-\(UUID().uuidString).bookbook")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let foreign = LockOwner(pid: 4242, host: "Other.local", acquiredAt: Date(), hostID: "FOREIGN-HOST")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(foreign).write(to: dir.appendingPathComponent(".lock"))

        let store = BookStore(packageURL: dir)
        guard case .heldByOther(let owner) = try await store.acquireLock() else {
            Issue.record("expected a foreign lock to be held")
            return
        }
        #expect(owner.host == "Other.local")
        let outcome = await LockTakeOver.takeOver(store, from: owner)
        #expect(outcome == .taken)
        await store.releaseLock()
    }
}
