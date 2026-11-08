import SwiftUI

/// The Settings scene content (A §6.1). Stub with a General tab.
public struct SettingsView: View {
    public init() {}

    public var body: some View {
        TabView {
            Form {
                Text("General settings will appear here.")
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 460, height: 260)
    }
}
