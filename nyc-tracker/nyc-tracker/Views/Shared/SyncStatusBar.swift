import SwiftUI

/// "1 entry" / "3 entries".
///
/// Written out rather than using `^[\(n) entry](inflect: true)`: that markup is
/// only processed when the string reaches `Text` as a `LocalizedStringKey`, and
/// every call site here builds a `String` first — where it would render as
/// literal markup on screen. The app ships one language, so a helper is both
/// safer and clearer than getting the localisation plumbing exactly right.
func entryCountLabel(_ count: Int) -> String {
    "\(count) \(count == 1 ? "entry" : "entries")"
}

/// A small floating pill over the map that appears only when there is something
/// to say.
///
/// The rule it follows: silence when everything is fine. A permanent "synced"
/// badge is visual noise that people stop reading within a day, which means it
/// is also not there when it turns into a warning. So the bar is absent in the
/// steady state and present — with a specific count and an action — when work is
/// queued, failing, or migrating.
///
/// Failures are shown rather than hidden. An entry that will never upload on its
/// own is exactly the thing the user needs to know about, and the retry button
/// is the affordance that makes telling them useful.
struct SyncStatusBar: View {
    @Environment(SyncEngine.self) private var sync

    var body: some View {
        Group {
            if let migration = sync.migrationProgress {
                migrationPill(migration)
            } else if sync.failedCount > 0 {
                failurePill
            } else if sync.pendingCount > 0 {
                pendingPill
            }
        }
        .animation(.snappy, value: sync.pendingCount)
        .animation(.snappy, value: sync.failedCount)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    // MARK: - Variants

    /// Migration of pre-auth entries. Progress, not a spinner, because this can
    /// cover dozens of visits and "how much longer" is the only question the
    /// user actually has. Nothing here blocks the app.
    private func migrationPill(_ progress: SyncEngine.MigrationProgress) -> some View {
        HStack(spacing: 10) {
            ProgressView(value: progress.fraction)
                .progressViewStyle(.circular)
                .controlSize(.small)

            VStack(alignment: .leading, spacing: 1) {
                Text("Moving your places to your account")
                    .font(.footnote.weight(.semibold))
                Text("\(progress.completed) of \(progress.total)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .glassEffect(.regular, in: .capsule)
    }

    private var failurePill: some View {
        Button {
            Haptics.tap()
            sync.retryFailedNow()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.icloud.fill")
                    .foregroundStyle(.orange)
                Text("\(entryCountLabel(sync.failedCount)) didn't upload")
                    .font(.footnote.weight(.semibold))
                Text("Retry")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
        .buttonStyle(.glass)
        .accessibilityLabel("\(entryCountLabel(sync.failedCount)) didn't upload. Tap to retry.")
    }

    private var pendingPill: some View {
        HStack(spacing: 8) {
            if sync.isSyncing {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: NetworkMonitor.shared.isReachable ? "clock" : "wifi.slash")
                    .foregroundStyle(.secondary)
            }
            Text(pendingLabel)
                .font(.footnote.weight(.semibold))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .glassEffect(.regular, in: .capsule)
        .accessibilityLabel(pendingLabel)
    }

    private var pendingLabel: String {
        if sync.isSyncing {
            return "Uploading…"
        }
        if !NetworkMonitor.shared.isReachable {
            // Naming the reason matters here: "1 waiting" next to a pin the user
            // just dropped in airplane mode reads as a failure. "Saved — will
            // upload when you're back online" says the entry is safe.
            return "Saved offline — \(entryCountLabel(sync.pendingCount)) will upload later"
        }
        return "\(entryCountLabel(sync.pendingCount)) waiting to upload"
    }
}
