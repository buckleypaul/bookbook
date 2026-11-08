import BBAI
import SwiftUI

/// Plain-language failure advice (A §7.11): headline, explanation, best-guess fixes, a console
/// link, and the provider's raw details tucked under a disclosure.
struct FailureAdviceView: View {
    let advice: FailureAdvice
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(advice.headline, systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.red)
            if !advice.explanation.isEmpty {
                Text(advice.explanation).font(.caption).fixedSize(horizontal: false, vertical: true)
            }
            if !advice.fixes.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(advice.fixes, id: \.self) { fix in
                        Text("• " + fix).font(.caption).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let link = advice.link {
                Link("Open the provider's website", destination: link).font(.caption)
            }
            if let details = advice.details, !details.isEmpty {
                DisclosureGroup("Details", isExpanded: $showDetails) {
                    Text(details)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 2)
                }
                .font(.caption)
            }
        }
    }
}
