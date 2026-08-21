import SwiftUI
import PhotosUI
import UIKit

/// Settings, now backed by the real account rather than a placeholder.
///
/// Covers everything the App Store requires for an account-based app: see your
/// identity, edit it, sign out, and — the one that gets apps rejected if it's
/// missing — delete the account from inside the app.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AuthManager.self) private var auth
    @Environment(SyncEngine.self) private var sync

    @State private var displayName = ""
    @State private var isSaving = false

    @State private var avatarItem: PhotosPickerItem?
    @State private var isUploadingAvatar = false

    @State private var showSignOutConfirmation = false
    @State private var showDeleteSheet = false

    @State private var error: PresentableError?

    private var profile: Profile? { auth.state.profile }

    /// Only enable Save when something actually changed — a Save button that's
    /// always live invites pointless writes and makes "did that save?" ambiguous.
    private var hasChanges: Bool {
        guard let profile else { return false }
        let currentName = profile.displayName ?? ""
        return displayName.trimmingCharacters(in: .whitespacesAndNewlines) != currentName
    }

    var body: some View {
        List {
            identitySection
            profileSection
            signOutSection
            dangerSection
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .listSectionSpacing(24)
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") {
                    Task { await saveProfile() }
                }
                .fontWeight(.semibold)
                .disabled(!hasChanges || isSaving)
            }
        }
        .onAppear { loadFields() }
        .onChange(of: avatarItem) { _, item in
            guard let item else { return }
            Task { await uploadAvatar(item) }
        }
        // Sign-out with pending uploads: **warn, and preserve the queue.**
        //
        // The three options were upload-first, discard, or preserve. Uploading
        // first is wrong because it makes sign-out block on a network the user
        // may not have — a person signing out on a plane would be stuck in the
        // app, and the whole point of the local-first design is that the
        // network is never on the critical path. Discarding is obviously
        // wrong: it destroys work the user can still see on screen.
        //
        // Preserving is safe precisely because rows are scoped by
        // `ownerUserID`. The queue stays on disk, invisible to whoever signs
        // in next, and drains automatically when its owner returns. The
        // warning exists so that outcome is stated rather than discovered —
        // "will finish uploading next time you sign in" is a promise the
        // engine actually keeps.
        .confirmationDialog(
            sync.hasUnsyncedWork ? "Sign out with unsynced entries?" : "Sign out of NYC Log?",
            isPresented: $showSignOutConfirmation,
            titleVisibility: .visible
        ) {
            if sync.hasUnsyncedWork && NetworkMonitor.shared.isReachable {
                Button("Upload now") {
                    Task {
                        await sync.refreshNow()
                        if !sync.hasUnsyncedWork {
                            await auth.signOut()
                            dismiss()
                        }
                    }
                }
            }
            Button("Sign out", role: .destructive) {
                Task {
                    await auth.signOut()
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if sync.hasUnsyncedWork {
                Text("\(entryCountLabel(sync.pendingCount + sync.failedCount)) hasn't uploaded yet. They'll stay on this device and finish uploading the next time you sign in to this account.")
            } else {
                Text("Everything you've logged is safely in the cloud.")
            }
        }
        .sheet(isPresented: $showDeleteSheet) {
            DeleteAccountView()
        }
        .alert(
            error?.title ?? "Something went wrong",
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

    // MARK: - Sections

    private var identitySection: some View {
        Section {
            VStack(spacing: 10) {
                avatarPicker
                    .frame(width: 108, height: 108)
                    .clipShape(Circle())
                    .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 4)

                VStack(spacing: 3) {
                    Text(profile?.bestName ?? "—")
                        .font(.title3.weight(.semibold))
                    Text(profile?.handle ?? "")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }
    }

    private var avatarPicker: some View {
        PhotosPicker(selection: $avatarItem, matching: .images, photoLibrary: .shared()) {
            ZStack {
                AvatarImage(urlString: profile?.avatarURL) {
                    avatarPlaceholder
                }

                if isUploadingAvatar {
                    Color.black.opacity(0.4)
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "pencil.circle.fill")
                    .font(.system(size: 18))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.accentColor)
                    .offset(x: 2, y: 2)
            }
        }
        .buttonStyle(.plain)
        .disabled(isUploadingAvatar)
        .accessibilityLabel("Change profile photo")
    }

    @ViewBuilder
    private var avatarPlaceholder: some View {
        if let profile {
            PersonInitialsView(person: profile.personSummary)
        } else {
            PersonUnknownAvatar()
        }
    }

    private var profileSection: some View {
        Section {
            LabeledField(
                title: "Display name",
                text: $displayName,
                placeholder: "Your name",
                showsBackground: false
            )
            .textContentType(.name)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)

            // Usernames are the identity other people search by and link to, so
            // changing one is not a settings toggle — it needs a redirect story
            // first. Shown read-only rather than hidden so it's clearly deliberate.
            readOnlyField(
                title: "Username",
                value: profile?.username.map { "@\($0)" } ?? "—"
            )
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        } header: {
            Text("Profile")
        }
    }

    private func readOnlyField(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .textFieldStyle(.plain)
                .padding(.vertical, 4)
        }
    }

    private var signOutSection: some View {
        Section {
            Button {
                Haptics.tap()
                showSignOutConfirmation = true
            } label: {
                Text("Sign out")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity, minHeight: 30)
            }
            .buttonStyle(.glass)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }
    }

    private var dangerSection: some View {
        Section {
            Button {
                Haptics.tap()
                showDeleteSheet = true
            } label: {
                Text("Delete account")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity, minHeight: 30)
            }
            .buttonStyle(.glassProminent)
            .tint(.red)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        } header: {
            Text("Delete account")
        } footer: {
            Text("Deleting your account permanently removes your profile, visits, photos, and friendships. This cannot be undone.")
        }
    }

    // MARK: - Actions

    private func loadFields() {
        guard let profile else { return }
        displayName = profile.displayName ?? ""
    }

    private func saveProfile() async {
        isSaving = true
        defer { isSaving = false }

        do {
            let updated = try await ProfileService.updateProfile(
                displayName: displayName,
                bio: profile?.bio
            )
            auth.apply(updated)
            Haptics.success()
        } catch {
            self.error = SupabaseErrorPresenter.presentable(error, context: .profileUpdate)
        }
    }

    private func uploadAvatar(_ item: PhotosPickerItem) async {
        isUploadingAvatar = true
        defer {
            isUploadingAvatar = false
            avatarItem = nil
        }

        // Same treatment as visit photos, via the same code: square-cropped,
        // downscaled, and re-encoded from bare pixels so no EXIF (including the
        // location the selfie was taken) rides along into a public bucket.
        guard
            let data = try? await item.loadTransferable(type: Data.self),
            let jpeg = await Task.detached(priority: .userInitiated, operation: {
                ImagePreparer.prepareAvatar(data)
            }).value
        else {
            error = PresentableError(
                title: "Couldn't read photo",
                message: "That image couldn't be loaded. Try a different one.",
                isRetryable: false
            )
            return
        }

        do {
            let updated = try await ProfileService.uploadAvatar(jpeg)
            auth.apply(updated)
            Haptics.success()
        } catch {
            self.error = SupabaseErrorPresenter.presentable(error, context: .avatarUpload)
        }
    }
}

// Avatar downscaling now lives in `ImagePreparer.prepareAvatar`, shared with the
// visit-photo path — one resize implementation, one place where metadata is
// stripped, and no chance of the two drifting apart.

#Preview {
    NavigationStack {
        SettingsView()
    }
    .environment(AuthManager())
    .environment(SyncEngine())
    .environment(AppRouter())
}
