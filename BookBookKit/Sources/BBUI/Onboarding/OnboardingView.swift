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

/// PD §8.13 guided setup. Every step can be skipped; "Skip Setup" closes it.
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
            HStack {
                Spacer()
                StepDots(current: model.step.rawValue, count: OnboardingModel.Step.allCases.count)
            }
            // Long content (a failure's advice, say) scrolls; the buttons below stay put.
            ScrollView {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            }
            .scrollBounceBehavior(.basedOnSize)
            HStack {
                Button("Skip Setup") { model.skipSetup(); close() }
                    .opacity(model.isLast ? 0 : 1)
                    .disabled(model.isLast)
                    .accessibilityHidden(model.isLast)
                Spacer()
                Button("Back") { model.back() }.disabled(model.isFirst)
                if !model.isLast {
                    // "Skip" only where there's something to skip; the row keeps its shape elsewhere.
                    let hasSomethingToSkip = model.step == .pasteKey
                    Button("Skip") { model.skipStep() }
                        .opacity(hasSomethingToSkip ? 1 : 0)
                        .disabled(!hasSomethingToSkip)
                        .accessibilityHidden(!hasSomethingToSkip)
                    // On the paste-key step Return saves and tests the key (the field's `onSubmit`),
                    // so Return isn't also Continue there.
                    Button("Continue") { model.next() }
                        .keyboardShortcut(model.step == .pasteKey ? nil : .defaultAction)
                        .buttonStyle(.crayon)
                } else {
                    Button("Done") { model.finish(); close() }.keyboardShortcut(.defaultAction)
                        .buttonStyle(.crayon(Crayon.grass))
                }
            }
        }
        .padding(24)
        .frame(width: 540, height: 460)
        .crayonPaper()
        .onAppear { model.reset(); app.refreshKeyStatus() }
        // The close button counts as skipping: otherwise it reopens every launch (#4a).
        .onDisappear { model.skipSetup(); draft = ""; testResult = nil }
    }

    private func close() { draft = ""; dismiss() }

    @ViewBuilder
    private var content: some View {
        switch model.step {
        case .whatIsAKey:
            page("What is an API key?") {
                Text("BookBook makes pictures with OpenAI's image models. An API key is a private password that lets BookBook ask OpenAI for images on your behalf. You pay OpenAI directly for what you use; BookBook itself charges nothing.")
                Text("Your key is stored in the macOS Keychain and is sent only to OpenAI.")
                    .foregroundStyle(Crayon.inkSoft)
            }
        case .getAKey:
            page("Get an OpenAI key") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("1. Sign in (or create an account) at platform.openai.com.")
                    Text("2. Add a payment method and a little credit under Billing.")
                    Text("3. Open the API keys page and choose Create new secret key.")
                    Text("4. Copy the key. OpenAI shows it only once.")
                }
                HStack(spacing: 16) {
                    linkButton("Open Billing", Self.billingURL)
                    linkButton("Open API Keys", Self.keysURL)
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
                        Label("Saved in your Keychain", systemImage: "checkmark.seal.fill").foregroundStyle(Crayon.grass)
                    }
                }
                if let error { CrayonInlineMessage(error, kind: .error, textStyle: .callout) }
                switch testResult {
                case let .success(count):
                    Label("Connected — \(count) models available", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Crayon.grass)
                case let .failure(advice): FailureAdviceView(advice: advice)
                case nil: EmptyView()
                }
            }
        case .costs:
            costsPage
        case .verifyOrganization:
            page("One more thing") {
                Text("OpenAI may ask you to verify your organization before its image models can be used. If generating fails with a message about access, verify your organization in OpenAI's settings; it can take a little while to take effect.")
                linkButton("Open Organization Settings", Self.organizationURL)
            }
        }
    }

    /// A link that reads as one: crayon blue, underlined, with an arrow.
    private func linkButton(_ title: String, _ url: URL) -> some View {
        Link(destination: url) {
            Label(title, systemImage: "arrow.up.right.square")
                .font(Crayon.font(.body, weight: .semibold))
                .underline()
        }
        .foregroundStyle(Crayon.sky)
    }

    private func costText(_ amount: Decimal?) -> String {
        amount == nil ? "Not available" : TypicalCosts.format(amount)
    }

    private var costsPage: some View {
        let costs = app.typicalCosts()
        return page("What it costs") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow { Text("One image, Draft quality"); Text(costText(costs.draftPerImage)) }
                GridRow { Text("One image, Standard quality"); Text(costText(costs.standardPerImage)) }
                GridRow {
                    Text("A \(TypicalCosts.bookPages)-page book at Standard")
                    Text(costText(costs.bookAtStandard))
                }
            }
            Text("Estimates for \(costs.modelName) at \(String(TypicalCosts.imageSize.width)) × \(String(TypicalCosts.imageSize.height)). Each refinement adds roughly the cost of another image. BookBook shows an estimate before you generate and asks first if it's high.")
                .font(.callout).foregroundStyle(Crayon.inkSoft)
            if let asOf = costs.priceListAsOf, !asOf.isEmpty {
                Text("Prices as of \(asOf).")
                    .font(.callout).foregroundStyle(Crayon.inkSoft)
            }
        }
    }

    private func page<C: View>(_ title: String, @ViewBuilder _ body: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                CrayonBlobIcon(systemImage: stepSymbol, color: Crayon.color(for: model.step.rawValue), size: 40)
                Text(title)
                    .font(Crayon.font(.title, weight: .heavy))
                    .foregroundStyle(Crayon.ink)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(alignment: .leading, spacing: 12) {
                body()
            }
            .foregroundStyle(Crayon.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .crayonCard(padding: 16)
        }
    }

    /// Each step gets its own crayon and picture.
    private var stepSymbol: String {
        switch model.step {
        case .whatIsAKey: "key.fill"
        case .getAKey: "person.badge.key.fill"
        case .pasteKey: "doc.on.clipboard.fill"
        case .costs: "dollarsign"
        case .verifyOrganization: "checkmark.shield.fill"
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
