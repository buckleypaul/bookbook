import Foundation

extension AppModel {
    /// PD §8.13: show the guided setup on first launch only.
    public func shouldShowOnboardingOnLaunch() -> Bool {
        refreshKeyStatus()
        return OnboardingState().shouldShowOnLaunch(hasKey: hasOpenAIKey)
    }

    /// The effective-price-list costs for the guided setup, for the default image model.
    public func typicalCosts() -> TypicalCosts {
        TypicalCosts(model: catalog.defaultImageModel(for: .openai), priceList: prices.current)
    }
}
