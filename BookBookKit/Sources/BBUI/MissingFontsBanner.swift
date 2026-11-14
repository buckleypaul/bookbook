import SwiftUI

/// Shown in the book window when the book names fonts that aren't installed or imported
/// (PD §8.2). The system font is used instead until they are. "Typography…" opens the form
/// where a font can be imported (none when the book can't be changed).
struct MissingFontsBanner: View {
    let fonts: [String]
    var onShowTypography: (() -> Void)? = nil

    var body: some View {
        CrayonBanner("These fonts are missing and the system font is used instead: \(fonts.joined(separator: ", "))",
                     systemImage: "textformat.alt", color: Crayon.sunflower, glyphColor: Crayon.onSunflower) {
            if let onShowTypography {
                Button("Typography…", action: onShowTypography)
                    .buttonStyle(.crayon(Crayon.sunflower))
                    .help("Import the missing fonts, or choose others.")
            }
        }
        .accessibilityIdentifier("missing-fonts-banner")
    }
}
