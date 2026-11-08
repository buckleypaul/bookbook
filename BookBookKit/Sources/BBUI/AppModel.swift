import Observation

/// App-wide observable state, injected with `.environment`. Empty until later phases.
@MainActor @Observable
public final class AppModel {
    public init() {}
}
