import Foundation

extension AppModel {
    /// PD §8.13: show the guided setup on first launch only.
    public func shouldShowOnboardingOnLaunch() -> Bool {
        refreshKeyStatus()
        return OnboardingState().shouldShowOnLaunch(hasKey: hasOpenAIKey)
    }

    /// The effective-price-list costs for the guided setup, for the user's preferred image model
    /// when it's in the catalog, else the catalog's default.
    public func typicalCosts() -> TypicalCosts {
        let model = catalog.resolve(provider: .openai, id: preferences.defaultImageModelID)
            ?? catalog.defaultImageModel(for: .openai)
        return TypicalCosts(model: model, priceList: prices.current)
    }
}
