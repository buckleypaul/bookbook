import BBAI
import SwiftUI

/// Plain-language failure advice (A §7.11): headline, explanation, best-guess fixes, a console
/// link, and the provider's raw details tucked under a disclosure.
struct FailureAdviceView: View {
    let advice: FailureAdvice
    @State private var showDetails = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Crayon.mediumCornerRadius, style: .continuous)
        VStack(alignment: .leading, spacing: 5) {
            Label {
                Text(advice.headline).foregroundStyle(Crayon.ink)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(CrayonContrast.label(on: Crayon.danger, preferring: .white,
                                                          minimum: CrayonContrast.graphics, in: colorScheme),
                                     Crayon.danger)
            }
            .font(Crayon.font(.callout, weight: .bold))
            if !advice.explanation.isEmpty {
                Text(advice.explanation).font(.caption).foregroundStyle(Crayon.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !advice.fixes.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(advice.fixes, id: \.self) { fix in
                        Text("• " + fix).font(.caption).foregroundStyle(Crayon.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let link = advice.link {
                Link("Open the provider's website", destination: link).font(Crayon.font(.caption, weight: .semibold))
            }
            if let details = advice.details, !details.isEmpty {
                DisclosureGroup("Details", isExpanded: $showDetails) {
                    Text(details)
                        .font(.caption.monospaced())
                        .foregroundStyle(Crayon.inkSoft)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 2)
                }
                .font(.caption)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Crayon.tomato.opacity(0.09), in: shape)
        .overlay(shape.strokeBorder(Crayon.tomato.opacity(0.35), lineWidth: 1.5))
    }
}
