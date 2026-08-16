import SwiftUI

/// One-time onboarding: pick a username.
///
/// There is no dismiss, no Cancel, and no skip. The screen is presented by
/// `RootView` as a full replacement rather than a sheet, so there is nothing to
/// swipe away — a user with a session but no username has an account without an
/// identity, and every social feature keys off the handle.
struct UsernameSetupView: View {
    @Environment(AuthManager.self) private var auth

    @State private var username = ""
    @State private var displayName = ""
    @State private var availability: Availability = .idle
    @State private var isSubmitting = false
    @State private var submitError: PresentableError?
    @FocusState private var focusedField: Field?

    private enum Field { case username, displayName }

    /// Server-side availability, separate from local format validation. `.checking`
    /// exists so the UI can say "checking…" instead of flickering between
    /// available and taken while the debounce settles.
    private enum Availability: Equatable {
        case idle
        case checking
        case available
        case taken
        case failed
    }

    private var validation: ProfileService.UsernameValidation {
        ProfileService.validate(username: username)
    }

    private var canSubmit: Bool {
        validation.isValid && availability == .available && !isSubmitting
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    usernameField
                } header: {
                    Text("Username")
                } footer: {
                    statusFooter
                }

                Section {
                    TextField("Your name", text: $displayName)
                        .textContentType(.name)
                        .focused($focusedField, equals: .displayName)
                        .submitLabel(.done)
                } header: {
                    Text("Display name")
                } footer: {
                    Text("Shown on your profile and next to the places you log. You can change it later.")
                }

                Section {
                    Button {
                        Task { await submit() }
                    } label: {
                        HStack {
                            Spacer()
                            if isSubmitting {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Continue").fontWeight(.semibold)
                            }
                            Spacer()
                        }
                    }
                    .disabled(!canSubmit)
                }
            }
            .navigationTitle("Choose a username")
            .navigationBarTitleDisplayMode(.inline)
            // No toolbar items on purpose: nothing here dismisses the screen.
            .interactiveDismissDisabled(true)
            .scrollDismissesKeyboard(.interactively)
        }
        .onAppear {
            // Apple returns the user's name only on their very first
            // authorization. `pendingAppleDisplayName` holds it for exactly this
            // moment; on a later sign-in it's nil and the field starts empty.
            if displayName.isEmpty, let appleName = auth.pendingAppleDisplayName {
                displayName = appleName
            }
            focusedField = .username
        }
        // Debounced availability check.
        //
        // `.task(id:)` cancels and restarts whenever `username` changes, so the
        // sleep below is the debounce: keystrokes inside 500ms cancel the pending
        // task before it ever hits the network. No timers, no manual bookkeeping,
        // and no stale response overwriting a newer one — the cancelled task can't
        // reach its assignment.
        .task(id: username) {
            let candidate = username.trimmingCharacters(in: .whitespacesAndNewlines)

            guard ProfileService.validate(username: candidate).isValid else {
                availability = .idle
                return
            }

            availability = .checking
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return   // superseded by a newer keystroke
            }

            do {
                let free = try await ProfileService.isUsernameAvailable(candidate)
                guard !Task.isCancelled else { return }
                availability = free ? .available : .taken
            } catch {
                guard !Task.isCancelled else { return }
                // Don't block the user on a flaky network — let them submit and
                // let the unique index be the judge.
                availability = .failed
            }
        }
        .alert(
            submitError?.title ?? "Something went wrong",
            isPresented: Binding(
                get: { submitError != nil },
                set: { if !$0 { submitError = nil } }
            ),
            presenting: submitError
        ) { _ in
            Button("OK", role: .cancel) { submitError = nil }
        } message: { error in
            Text(error.message)
        }
    }

    // MARK: - Pieces

    private var usernameField: some View {
        HStack(spacing: 6) {
            Text("@")
                .foregroundStyle(.secondary)

            TextField("username", text: $username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(.username)
                .focused($focusedField, equals: .username)
                .submitLabel(.next)
                .onChange(of: username) { _, newValue in
                    // Normalise as they type so the field can never hold something
                    // the database would reject. Uppercase is folded rather than
                    // rejected — typing "Will" and being told it's invalid is a
                    // worse experience than watching it become "will".
                    let cleaned = String(
                        newValue
                            .lowercased()
                            .filter { $0 == "_" || ($0.isASCII && ($0.isLetter || $0.isNumber)) }
                            .prefix(20)
                    )
                    if cleaned != newValue { username = cleaned }
                }
                .onSubmit { focusedField = .displayName }

            statusIcon
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch availability {
        case .idle:
            EmptyView()
        case .checking:
            ProgressView().controlSize(.small)
        case .available:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel("Available")
        case .taken:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
                .accessibilityLabel("Taken")
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
                .accessibilityLabel("Couldn't check")
        }
    }

    @ViewBuilder
    private var statusFooter: some View {
        if let message = validation.message {
            Text(message).foregroundStyle(.secondary)
        } else {
            switch availability {
            case .available:
                Text("@\(username) is available.").foregroundStyle(.green)
            case .taken:
                Text("@\(username) is taken. Try another.").foregroundStyle(.red)
            case .failed:
                Text("Couldn't check availability. You can still continue.")
                    .foregroundStyle(.orange)
            case .checking, .idle:
                Text("3–20 characters. Lowercase letters, numbers, and underscores.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Submit

    private func submit() async {
        guard !isSubmitting else { return }
        isSubmitting = true
        defer { isSubmitting = false }

        focusedField = nil

        do {
            let profile = try await ProfileService.setUsername(
                username,
                displayName: displayName
            )
            Haptics.success()
            // Hands the fresh profile back to the single owner of AuthState,
            // which flips the gate to `.signedIn`.
            auth.apply(profile)
        } catch {
            // The debounced check is an affordance, not a lock. Two people can
            // both see "available" and race; the unique index decides and the
            // loser lands here with a 23505.
            let presentable = SupabaseErrorPresenter.presentable(error, context: .usernameSetup)
            submitError = presentable
            if presentable.title == "Username taken" {
                availability = .taken
            }
            Haptics.warning()
        }
    }
}
