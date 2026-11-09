import Foundation
import Observation

/// First-run state (PD §8.13): whether to show the guided setup. The flag is a plain
/// `UserDefaults` bool; the API key never touches it.
public struct OnboardingState: @unchecked Sendable {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var isCompleted: Bool { defaults.bool(forKey: AppPreferences.Key.onboardingCompleted) }
    public func markCompleted() { defaults.set(true, forKey: AppPreferences.Key.onboardingCompleted) }

    /// Show on first launch only: flag unset, no key saved, and not under XCTest.
    public func shouldShowOnLaunch(hasKey: Bool, underTests: Bool = Self.runningUnderTests) -> Bool {
        !underTests && !hasKey && !isCompleted
    }

    public static var runningUnderTests: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil || env["XCTestBundlePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }
}

@MainActor @Observable
public final class OnboardingModel {
    public enum Step: Int, CaseIterable, Sendable {
        case whatIsAKey, getAKey, pasteKey, costs, verifyOrganization
    }

    public private(set) var step: Step = .whatIsAKey
    @ObservationIgnored private let state: OnboardingState

    public init(state: OnboardingState = OnboardingState()) { self.state = state }

    public var isFirst: Bool { step == Step.allCases.first }
    public var isLast: Bool { step == Step.allCases.last }

    public func next() {
        if let n = Step(rawValue: step.rawValue + 1) { step = n } else { finish() }
    }
    public func back() {
        if let p = Step(rawValue: step.rawValue - 1) { step = p }
    }
    /// Every step is skippable: moves on without requiring anything.
    public func skipStep() { next() }

    public func finish() { state.markCompleted() }
    /// "Skip setup": same flag as finishing.
    public func skipSetup() { state.markCompleted() }
}
