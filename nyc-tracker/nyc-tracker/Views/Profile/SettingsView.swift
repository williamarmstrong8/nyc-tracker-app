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
    @State private var bio = ""
    @State private var isSaving = false
    @State private var savedRecently = false

    @State private var avatarItem: PhotosPickerItem?
    @State private var isUploadingAvatar = false

    @State private var showSignOutConfirmation = false
    @State private var showDeleteSheet = false

    @State private var error: PresentableError?

    private var profile: Profile? { auth.state.profile }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }
    private var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    /// Only enable Save when something actually changed — a Save button that's
    /// always live invites pointless writes and makes "did that save?" ambiguous.
    private var hasChanges: Bool {
        guard let profile else { return false }
        let currentName = profile.displayName ?? ""
        let currentBio = profile.bio ?? ""
        return displayName.trimmingCharacters(in: .whitespacesAndNewlines) != currentName
            || bio.trimmingCharacters(in: .whitespacesAndNewlines) != currentBio
    }

    var body: some View {
        NavigationStack {
            Form {
                accountSection
                profileSection
                aboutSection
                dangerSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear(perform: loadFields)
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
    }

    // MARK: - Sections

    private var accountSection: some View {
        Section("Account") {
            HStack(spacing: 14) {
                avatarPicker

                VStack(alignment: .leading, spacing: 3) {
                    Text(profile?.bestName ?? "—")
                        .font(.headline)
                    if let handle = profile?.handle {
                        Text(handle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()
            }
            .padding(.vertical, 4)

            // Usernames are the identity other people search by and link to, so
            // changing one is not a settings toggle — it needs a redirect story
            // first. Shown read-only rather than hidden so it's clearly deliberate.
            LabeledContent("Username", value: profile?.username.map { "@\($0)" } ?? "—")
                .foregroundStyle(.secondary)
        }
    }

    private var avatarPicker: some View {
        PhotosPicker(selection: $avatarItem, matching: .images, photoLibrary: .shared()) {
            ZStack {
                if let urlString = profile?.avatarURL, let url = URL(string: urlString) {
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        avatarPlaceholder
                    }
                } else {
                    avatarPlaceholder
                }

                if isUploadingAvatar {
                    Color.black.opacity(0.4)
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                }
            }
            .frame(width: 58, height: 58)
            .clipShape(Circle())
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

    private var avatarPlaceholder: some View {
        ZStack {
            Color(uiColor: .tertiarySystemFill)
            Image(systemName: "person.fill")
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
        }
    }

    private var profileSection: some View {
        Section {
            TextField("Display name", text: $displayName)
                .textContentType(.name)

            TextField("Bio", text: $bio, axis: .vertical)
                .lineLimit(2...5)

            Button {
                Task { await saveProfile() }
            } label: {
                HStack {
                    Text(savedRecently ? "Saved" : "Save changes")
                    Spacer()
                    if isSaving {
                        ProgressView().controlSize(.small)
                    } else if savedRecently {
                        Image(systemName: "checkmark").foregroundStyle(.green)
                    }
                }
            }
            .disabled(!hasChanges || isSaving)
        } header: {
            Text("Profile")
        } footer: {
            Text("Your display name and bio are visible to everyone on NYC Log.")
        }
    }

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Version", value: "\(appVersion) (\(buildNumber))")
        }
    }

    private var dangerSection: some View {
        Section {
            Button("Sign out") {
                Haptics.tap()
                showSignOutConfirmation = true
            }

            Button("Delete account", role: .destructive) {
                Haptics.tap()
                showDeleteSheet = true
            }
        } footer: {
            Text("Deleting your account permanently removes your profile, visits, photos, and friendships. This cannot be undone.")
        }
    }

    // MARK: - Actions

    private func loadFields() {
        guard let profile else { return }
        displayName = profile.displayName ?? ""
        bio = profile.bio ?? ""
    }

    private func saveProfile() async {
        isSaving = true
        defer { isSaving = false }

        do {
            let updated = try await ProfileService.updateProfile(
                displayName: displayName,
                bio: bio
            )
            auth.apply(updated)
            Haptics.success()

            savedRecently = true
            try? await Task.sleep(for: .seconds(2))
            savedRecently = false
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
    SettingsView()
        .environment(AuthManager())
        .environment(SyncEngine())
}
