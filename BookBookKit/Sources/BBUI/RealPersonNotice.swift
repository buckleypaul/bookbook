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
            HStack(alignment: .center, spacing: 12) {
                CrayonBlobIcon(systemImage: "person.crop.square", color: Crayon.sky, size: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text(RealPersonNoticeText.question)
                        .font(Crayon.font(.title3, weight: .bold))
                        .foregroundStyle(Crayon.ink)
                    Text(fileName).font(Crayon.font(.caption, weight: .medium)).foregroundStyle(Crayon.inkSoft)
                }
            }
            Text(RealPersonNoticeText.questionDetail)
                .font(.callout)
                .foregroundStyle(Crayon.ink)
                .fixedSize(horizontal: false, vertical: true)
                .crayonCard(padding: 12)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                answerButton("No", answer: false)
                answerButton("Yes", answer: true)
            }
        }
        .padding(20)
        .frame(width: 400)
        .crayonPaper()
    }

    @ViewBuilder
    private func answerButton(_ title: String, answer: Bool) -> some View {
        if answer == defaultAnswer {
            Button(title) { onAnswer(answer) }.keyboardShortcut(.defaultAction).buttonStyle(.crayon(Crayon.sky))
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
            Label {
                Text(RealPersonNoticeText.title(provider))
                    .font(Crayon.font(.title3, weight: .bold))
                    .foregroundStyle(Crayon.ink)
            } icon: {
                CrayonBlobIcon(systemImage: "person.crop.square.badge.exclamationmark", color: Crayon.bubblegum,
                               size: 40)
            }
            .labelStyle(NoticeTitleLabelStyle())
            VStack(alignment: .leading, spacing: 10) {
                Text(RealPersonNoticeText.body(provider))
                    .font(.callout)
                    .foregroundStyle(Crayon.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let url = RealPersonNoticeText.policyURL(provider) {
                    Link("\(VersionDetailsContent.providerName(provider)) data policy", destination: url)
                        .font(Crayon.font(.callout, weight: .semibold))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .crayonCard(tint: Crayon.bubblegum, padding: 12)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Button("Continue", action: onContinue).keyboardShortcut(.defaultAction)
                    .buttonStyle(.crayon(Crayon.bubblegum))
            }
        }
        .padding(20)
        .frame(width: 440)
        .crayonPaper()
    }
}

/// The notice's title: the blob icon beside wrapping rounded text.
private struct NoticeTitleLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: 12) {
            configuration.icon
            configuration.title.fixedSize(horizontal: false, vertical: true)
        }
    }
}
