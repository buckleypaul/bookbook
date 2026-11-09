import SwiftUI

/// Scene id of the guided setup window (owned here; `SceneID` lives in AppModel.swift).
public enum OnboardingScene {
    public static let id = "onboarding"
}

/// Opens the guided setup once on first launch. Apply to the library window's content.
public struct OnboardingLauncher: ViewModifier {
    let app: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var checked = false

    public func body(content: Content) -> some View {
        content.task {
            guard !checked else { return }
            checked = true
            if app.shouldShowOnboardingOnLaunch() { openWindow(id: OnboardingScene.id) }
        }
    }
}

public extension View {
    func opensOnboardingOnFirstLaunch(_ app: AppModel) -> some View { modifier(OnboardingLauncher(app: app)) }
}

/// PD §8.13 guided setup. Every step can be skipped; "Skip setup" closes it.
public struct OnboardingView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var model = OnboardingModel()
    @State private var draft = ""
    @State private var error: String?
    @State private var testing = false
    @State private var testResult: ConnectionTestResult?

    static let keysURL = URL(string: "https://platform.openai.com/api-keys")!
    static let billingURL = URL(string: "https://platform.openai.com/settings/organization/billing/overview")!
    static let organizationURL = URL(string: "https://platform.openai.com/settings/organization/general")!

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Guided Setup").font(.caption).foregroundStyle(.secondary)
            content
            Spacer(minLength: 0)
            HStack {
                Button("Skip setup") { model.skipSetup(); close() }
                Spacer()
                if !model.isFirst { Button("Back") { model.back() } }
                if !model.isLast {
                    Button("Skip this step") { model.skipStep() }
                    Button("Continue") { model.next() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Done") { model.finish(); close() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 540, height: 460)
        .onAppear { app.refreshKeyStatus() }
        .onDisappear { draft = ""; testResult = nil }
    }

    private func close() { draft = ""; dismiss() }

    @ViewBuilder
    private var content: some View {
        switch model.step {
        case .whatIsAKey:
            page("What is an API key?") {
                Text("BookBook makes pictures with OpenAI's image models. An API key is a private password that lets BookBook ask OpenAI for images on your behalf. You pay OpenAI directly for what you use; BookBook itself charges nothing.")
                Text("Your key is stored in the macOS Keychain and is sent only to OpenAI.")
                    .foregroundStyle(.secondary)
            }
        case .getAKey:
            page("Get an OpenAI key") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("1. Sign in (or create an account) at platform.openai.com.")
                    Text("2. Add a payment method and a little credit under Billing.")
                    Text("3. Open the API keys page and choose Create new secret key.")
                    Text("4. Copy the key. OpenAI shows it only once.")
                }
                HStack {
                    Link("Open Billing", destination: Self.billingURL)
                    Link("Open API Keys", destination: Self.keysURL)
                }
            }
        case .pasteKey:
            page("Paste your key") {
                SecureField("OpenAI API key", text: $draft, prompt: Text("Paste your key"))
                    .privacySensitive()
                    .onSubmit(saveAndTest)
                HStack {
                    Button("Save and Test", action: saveAndTest)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || testing)
                    if testing { ProgressView().controlSize(.small) }
                    if app.hasOpenAIKey {
                        Label("Saved in your Keychain", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    }
                }
                if let error { Text(error).foregroundStyle(.red).font(.callout) }
                switch testResult {
                case let .success(count):
                    Label("Connected — \(count) models available", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case let .failure(advice): FailureAdviceView(advice: advice)
                case nil: EmptyView()
                }
            }
        case .costs:
            costsPage
        case .verifyOrganization:
            page("One more thing") {
                Text("OpenAI may ask you to verify your organization before its image models can be used. If generating fails with a message about access, verify your organization in OpenAI's settings; it can take a little while to take effect.")
                Link("Open organization settings", destination: Self.organizationURL)
            }
        }
    }

    private var costsPage: some View {
        let costs = app.typicalCosts()
        return page("What it costs") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow { Text("One image, Draft quality"); Text(TypicalCosts.format(costs.draftPerImage)) }
                GridRow { Text("One image, Standard quality"); Text(TypicalCosts.format(costs.standardPerImage)) }
                GridRow {
                    Text("A \(TypicalCosts.bookPages)-page book at Standard")
                    Text(TypicalCosts.format(costs.bookAtStandard))
                }
            }
            Text("Estimates for \(costs.modelName) at \(TypicalCosts.imageSize.width)×\(TypicalCosts.imageSize.height). Each refinement adds roughly the cost of another image. BookBook shows an estimate before you generate and asks first if it is high.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func page<C: View>(_ title: String, @ViewBuilder _ body: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title2.bold())
            body()
        }
    }

    private func saveAndTest() {
        do {
            let saved = try app.saveOpenAIKey(draft)
            draft = ""
            guard saved else { return }
            error = nil
        } catch {
            self.error = StoreErrorText.message(for: error)
            draft = ""
            return
        }
        testing = true
        testResult = nil
        Task {
            testResult = await app.testConnection(.openai)
            testing = false
        }
    }
}
