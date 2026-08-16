import SwiftUI

/// Placeholder settings screen reached from the gear button on Profile. Real preferences
/// (appearance, notifications, account management) land alongside the Supabase sync layer.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }
    private var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Account") {
                    Label("Sign in to sync", systemImage: "arrow.right.circle")
                        .foregroundStyle(.secondary)
                }
                .disabled(true)

                Section("About") {
                    LabeledContent("Version", value: "\(appVersion) (\(buildNumber))")
                }

                Section {
                    Text("More settings — appearance, notifications, and account management — are coming in a future update.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    SettingsView()
}
