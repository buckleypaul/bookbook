import SwiftUI

/// Shown in the book window when the book names fonts that aren't installed or imported
/// (PD §8.2). The system font is used instead until they are.
struct MissingFontsBanner: View {
    let fonts: [String]

    var body: some View {
        CrayonBanner("These fonts are missing and the system font is used instead: \(fonts.joined(separator: ", "))",
                     systemImage: "textformat.alt", color: Crayon.sunflower)
            .accessibilityIdentifier("missing-fonts-banner")
    }
}
