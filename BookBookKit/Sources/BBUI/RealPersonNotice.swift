import BBModel
import SwiftUI

/// The real-person photo texts (PD §3, A §11).
public enum RealPersonNoticeText {
    public static let question = "Is this a photo of a real person?"
    public static let questionDetail = "BookBook asks so it can tell you before a photo of a real person is sent to an AI provider."

    public static func title(_ provider: ProviderID) -> String {
        "A photo of a real person will be sent to \(VersionDetailsContent.providerName(provider))"
    }

    public static func body(_ provider: ProviderID) -> String {
        let name = VersionDetailsContent.providerName(provider)
        return "This request includes a reference you marked as a photo of a real person. It will be sent to "
            + "\(name) with the request, and \(name)'s data policy applies to it.\n\n"
            + "Providers restrict photos of children. For example, OpenAI's guidance says personal data of "
            + "children under 13 shouldn't be sent without a zero-data-retention arrangement, which individual "
            + "users don't normally have. Instead of a photo, consider describing the child in words, or using "
            + "a drawing."
    }

    /// The provider's data policy.
    public static func policyURL(_ provider: ProviderID) -> URL? {
        switch provider {
        case .openai: URL(string: "https://openai.com/policies/privacy-policy/")
        case .gemini: URL(string: "https://ai.google.dev/gemini-api/terms")
        default: nil
        }
    }
}

/// Asked when a picture is imported into an asset session. The default answer comes from
/// `BookDocument.looksCameraOriginated`.
struct RealPersonQuestionSheet: View {
    let fileName: String
    let defaultAnswer: Bool
    let onAnswer: (Bool) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(RealPersonNoticeText.question).font(.headline)
            Text(fileName).font(.caption).foregroundStyle(.secondary)
            Text(RealPersonNoticeText.questionDetail).font(.callout).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Cancel", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Spacer()
                answerButton("No", answer: false)
                answerButton("Yes", answer: true)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    @ViewBuilder
    private func answerButton(_ title: String, answer: Bool) -> some View {
        if answer == defaultAnswer {
            Button(title) { onAnswer(answer) }.keyboardShortcut(.defaultAction)
        } else {
            Button(title) { onAnswer(answer) }
        }
    }
}

/// Shown once per provider and book, before the first request that would send a photo of a
/// real person. Continue records the acknowledgement; Cancel sends nothing.
struct RealPersonNoticeSheet: View {
    let provider: ProviderID
    let onContinue: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(RealPersonNoticeText.title(provider), systemImage: "person.crop.square.badge.exclamationmark")
                .font(.headline)
            Text(RealPersonNoticeText.body(provider)).font(.callout).fixedSize(horizontal: false, vertical: true)
            if let url = RealPersonNoticeText.policyURL(provider) {
                Link("\(VersionDetailsContent.providerName(provider)) data policy", destination: url)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Button("Continue", action: onContinue).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
