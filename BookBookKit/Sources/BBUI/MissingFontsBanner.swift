import SwiftUI

/// Shown in the book window when the book names fonts that aren't installed or imported
/// (PD §8.2). The system font is used instead until they are.
struct MissingFontsBanner: View {
    let fonts: [String]

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Crayon.cornerRadius, style: .continuous)
        Label {
            Text("These fonts are missing and the system font is used instead: \(fonts.joined(separator: ", "))")
                .foregroundStyle(Crayon.ink)
        } icon: {
            Image(systemName: "textformat.alt")
                .font(.system(size: 12, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Crayon.sunflower))
                .shadow(color: Crayon.shadow, radius: 0, x: 0, y: 2)
        }
        .font(Crayon.font(.callout, weight: .semibold))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            shape.fill(Crayon.card)
                .overlay(shape.fill(Crayon.sunflower.opacity(0.22)))
                .overlay(shape.strokeBorder(Crayon.sunflower.opacity(0.7), lineWidth: 1.5))
                .shadow(color: Crayon.shadow, radius: 0, x: 0, y: 3)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .accessibilityIdentifier("missing-fonts-banner")
    }
}
