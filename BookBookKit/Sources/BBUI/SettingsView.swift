import BBAI
import BBModel
import BBStore
import SwiftUI

/// The Settings scene (A §6.1): General, and API Keys (A §5.5, plan §2.2).
public struct SettingsView: View {
    public init() {}

    public var body: some View {
        TabView {
            Form {
                LibraryLocationSettings()
            }
            .formStyle(.grouped)
            .frame(width: Self.paneWidth, height: 270)
            .tabItem { Label("General", systemImage: "gearshape") }

            APIKeysSettings()
                .frame(width: Self.paneWidth, height: 360)
                .tabItem { Label("API Keys", systemImage: "key") }

            ModelSettings()
                .frame(width: Self.paneWidth, height: 560)
                .tabItem { Label("Models", systemImage: "cpu") }

            CostSettings()
                .frame(width: Self.paneWidth, height: 560)
                .tabItem { Label("Cost", systemImage: "dollarsign.circle") }
        }
    }

    /// Each pane sizes the Settings window itself: short panes fit their content, the tall ones
    /// (Models, Cost) scroll inside a fixed height.
    private static let paneWidth: CGFloat = 580
}

/// The OpenAI key goes only to the Keychain: the field is plain view state (never
/// `@AppStorage`/`@SceneStorage`), is cleared once saved, and nothing logs it.
struct APIKeysSettings: View {
    @Environment(AppModel.self) private var app
    @State private var draft = ""
    @State private var error: String?
    @State private var testing = false
    @State private var testResult: ConnectionTestResult?
    @State private var confirmRemove = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            Section {
                SecureField("OpenAI API key", text: $draft, prompt: Text("Paste your key"))
                    .privacySensitive()
                    .onSubmit(save)
                HStack {
                    if app.hasOpenAIKey {
                        Label("Saved in your Keychain", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(Crayon.success)
                    } else {
                        Label("No key saved", systemImage: "key.slash").foregroundStyle(Crayon.inkSoft)
                    }
                    Spacer()
                    Button("Remove", role: .destructive) { confirmRemove = true }
                        .disabled(!app.hasOpenAIKey)
                    Button("Save", action: save)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .keyboardShortcut(.defaultAction)
                }
                if let error {
                    CrayonInlineMessage(error, kind: .error, textStyle: .callout)
                }
                connectionTest
                Button("Guided Setup…") { openWindow(id: OnboardingScene.id) }
            } header: {
                Text("OpenAI")
            } footer: {
                Text("BookBook keeps your key in the macOS Keychain and sends it only to OpenAI.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .alert("Remove your OpenAI API key?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive, action: remove)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("BookBook can't make pictures until you add a key again.")
        }
        .onAppear { app.refreshKeyStatus() }
        .onDisappear { draft = ""; testResult = nil }
    }

    @ViewBuilder
    private var connectionTest: some View {
        HStack {
            Button("Test Connection") { runTest() }
                .disabled(!app.hasOpenAIKey || testing)
            if testing { ProgressView().controlSize(.small) }
            Spacer()
        }
        switch testResult {
        case let .success(count):
            CrayonInlineMessage("Connected — \(count) models available", kind: .success, textStyle: .callout)
        case let .failure(advice):
            FailureAdviceView(advice: advice)
        case nil:
            EmptyView()
        }
    }

    private func runTest() {
        testing = true
        testResult = nil
        Task {
            testResult = await app.testConnection(.openai)
            testing = false
        }
    }

    private func save() {
        // Return in the field and the default Save button can both fire; the first clears the draft.
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        testResult = nil
        do {
            if try app.saveOpenAIKey(draft) { error = nil }
            draft = ""
        } catch {
            self.error = StoreErrorText.message(for: error)
            draft = ""
        }
    }

    private func remove() {
        testResult = nil
        do {
            try app.removeOpenAIKey()
            error = nil
        } catch {
            self.error = StoreErrorText.message(for: error)
        }
    }
}
