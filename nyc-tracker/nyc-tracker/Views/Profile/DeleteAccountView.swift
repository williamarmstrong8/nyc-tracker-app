import SwiftUI

/// Account deletion, behind a typed confirmation.
///
/// Apple requires an in-app path to delete an account (App Store Review Guideline
/// 5.1.1(v)), so this ships whether or not anyone uses it.
///
/// Typed confirmation rather than a plain "Are you sure?" dialog: the action is
/// irreversible and destroys every visit, photo, and friendship the user has, and
/// a two-tap destructive confirm is easy to fire by muscle memory. Typing the word
/// forces a deliberate pause.
struct DeleteAccountView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AuthManager.self) private var auth

    @State private var typedConfirmation = ""
    @State private var isDeleting = false
    @State private var error: PresentableError?

    private let requiredPhrase = "DELETE"

    private var canDelete: Bool {
        typedConfirmation.trimmingCharacters(in: .whitespaces).uppercased() == requiredPhrase
            && !isDeleting
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("This cannot be undone", systemImage: "exclamationmark.triangle.fill")
                            .font(.headline)
                            .foregroundStyle(.red)

                        Text("Deleting your account permanently removes:")
                            .font(.subheadline)

                        VStack(alignment: .leading, spacing: 6) {
                            bullet("Your profile and username")
                            bullet("Every visit, transcript, and write-up")
                            bullet("All uploaded photos")
                            bullet("Your friendships and recommendations")
                        }

                        Text("Your username is released and someone else can claim it.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                }

                Section {
                    TextField(requiredPhrase, text: $typedConfirmation)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .disabled(isDeleting)
                } header: {
                    Text("Type \(requiredPhrase) to confirm")
                }

                Section {
                    Button(role: .destructive) {
                        Task { await deleteAccount() }
                    } label: {
                        HStack {
                            Spacer()
                            if isDeleting {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Delete my account").fontWeight(.semibold)
                            }
                            Spacer()
                        }
                    }
                    .disabled(!canDelete)
                }
            }
            .navigationTitle("Delete account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isDeleting)
                }
            }
            .interactiveDismissDisabled(isDeleting)
            .alert(
                error?.title ?? "Couldn't delete account",
                isPresented: Binding(
                    get: { error != nil },
                    set: { if !$0 { error = nil } }
                ),
                presenting: error
            ) { _ in
                Button("OK", role: .cancel) { error = nil }
            } message: { error in
                Text(error.message)
            }
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•").foregroundStyle(.secondary)
            Text(text).font(.subheadline)
        }
    }

    private func deleteAccount() async {
        isDeleting = true
        defer { isDeleting = false }

        let succeeded = await auth.deleteAccount()

        if succeeded {
            Haptics.success()
            // No dismiss needed on success — AuthState flips to .signedOut and
            // RootView replaces the whole hierarchy, this sheet included.
        } else {
            error = auth.lastError ?? PresentableError(
                title: "Couldn't delete account",
                message: "Something went wrong. Please try again.",
                isRetryable: true
            )
            // Consumed here so RootView's alert doesn't also fire for the same
            // failure — two alerts for one error is a confusing pile-up.
            auth.lastError = nil
            Haptics.warning()
        }
    }
}

#Preview {
    DeleteAccountView()
        .environment(AuthManager())
}
