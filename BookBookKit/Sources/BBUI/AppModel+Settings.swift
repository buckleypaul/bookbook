import BBAI
import BBAICore
import BBModel
import BBStore
import Foundation

// Settings (PD §8.11, A §7.1): the connection test, model availability and custom models.

public enum ConnectionTestResult: Sendable {
    /// The key works; `modelCount` models are listed.
    case success(modelCount: Int)
    case failure(FailureAdvice)
}

extension AppModel {
    /// Calls the provider's list-models endpoint with the stored key, updates
    /// `modelAvailability` and `missingDefaultModel`. Concurrent calls share one request.
    public func testConnection(_ provider: ProviderID) async -> ConnectionTestResult {
        if let running = connectionTests[provider] { return await running.value }
        let task = Task { [weak self] () -> ConnectionTestResult in
            guard let self else { return .failure(FailureAdvice(headline: "Couldn't test the connection", explanation: "")) }
            return await self.runConnectionTest(provider)
        }
        connectionTests[provider] = task
        let result = await task.value
        if connectionTests[provider] == task { connectionTests[provider] = nil }
        return result
    }

    private func runConnectionTest(_ provider: ProviderID) async -> ConnectionTestResult {
        guard let lister = listers[provider] else {
            return .failure(FailureAdvice(headline: "Can't test this provider yet",
                                          explanation: "BookBook can't check this provider's models."))
        }
        do throws(ProviderError) {
            let ids = try await lister.listModelIDs()
            listedModels[provider] = ids
            refreshAvailability()
            return .success(modelCount: ids.count)
        } catch {
            return .failure(RefusalAdvisor.advise(error, context: AdviceContext(provider: provider, report: nil)))
        }
    }

    /// Recomputes `modelAvailability` from the last list-models results and the effective
    /// catalog, and `missingDefaultModel` for the Settings default.
    func refreshAvailability() {
        var availability: [String: ModelAvailability] = [:]
        for (provider, listed) in listedModels {
            for model in catalog.imageModels(for: provider) {
                availability[model.id] = catalog.availability(of: model, listed: listed)
            }
        }
        if modelAvailability != availability { modelAvailability = availability }

        let settings = defaults
        var missing: ModelAvailability?
        if let listed = listedModels[settings.provider] {
            if let model = catalog.imageModel(provider: settings.provider, id: settings.model) {
                let state = catalog.availability(of: model, listed: listed)
                if state != .available { missing = state }
            } else if !listed.contains(settings.model) {
                let fallback = bundledCatalog.defaultImageModel(for: settings.provider)?.id
                missing = .unavailable(successor: fallback == settings.model ? nil : fallback)
            }
        }
        if missingDefaultModel != missing { missingDefaultModel = missing }
    }

    /// Image models for the Settings picker: bundled plus custom, current first (then
    /// deprecated, then retired; catalog order within each).
    public func imageModels(for provider: ProviderID) -> [CatalogModel] {
        func rank(_ status: ModelStatus) -> Int {
            switch status {
            case .current: 0
            case .deprecated: 1
            case .retired: 2
            }
        }
        return catalog.imageModels(for: provider).enumerated()
            .sorted { (rank($0.element.status), $0.offset) < (rank($1.element.status), $1.offset) }
            .map(\.element)
    }

    /// Adds a custom model ID copying `family`; false if the family is unknown or the ID exists.
    @discardableResult
    public func addCustomModel(id: String, copying family: String, provider: ProviderID) -> Bool {
        let id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, let base = bundledCatalog.imageModel(provider: provider, id: family), base.copiesFrom == nil,
              catalog.imageModel(provider: provider, id: id) == nil else { return false }
        preferences.customModels.append(CustomModelSpec(provider: provider, id: id, copiesFrom: base.id))
        return true
    }

    /// Removes a custom model; if it was the default, the default goes back to the catalog's.
    public func removeCustomModel(_ spec: CustomModelSpec) {
        guard preferences.customModels.contains(spec) else { return }
        preferences.customModels.removeAll { $0 == spec }
        if spec.provider == defaults.provider, preferences.defaultImageModelID == spec.id {
            preferences.defaultImageModelID = bundledCatalog.defaultImageModel(for: spec.provider)?.id
                ?? GenerationDefaults.fallbackModel
        }
    }
}
