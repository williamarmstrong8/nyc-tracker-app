import SwiftUI
import SwiftData

/// Signed-in identity, a fast path into been / want-to-try / shared, and a
/// photo grid of everywhere visited.
/// Visit analytics used to sit in a "Friends" card here; they were noise on a
/// page that's for the person, not the social graph.
struct ProfileView: View {
    let userID: UUID
    @Binding var openedVisit: Visit?
    let filter: EntryFilter

    @Environment(AuthManager.self) private var auth
    @Environment(SyncEngine.self) private var sync
    @Environment(SocialStatsCache.self) private var socialStats
    @Environment(AppRouter.self) private var router
    @Environment(SocialGraph.self) private var graph
    @Environment(FeedStore.self) private var feed
    @Environment(FriendVisitCache.self) private var friendVisits
    @Environment(MapAudienceStore.self) private var audience
    @Environment(SocialDemoMode.self) private var demo

    @State private var showSettings = false
    @State private var showAddFriends = false
    @State private var social: OwnSocialStats?

    /// Scoped to the signed-in user, same predicate every other own-visit query uses.
    @Query private var visits: [Visit]

    /// Horizontal margin shared by every section on this page and by the
    /// "Add friends" toolbar button, so the identity row lines up with it
    /// instead of hugging the screen edge.
    private static let contentMargin: CGFloat = 20

    init(userID: UUID, openedVisit: Binding<Visit?>, filter: EntryFilter) {
        self.userID = userID
        _openedVisit = openedVisit
        self.filter = filter
        _visits = Query(
            filter: LocalStore.visitsPredicate(for: userID),
            sort: [SortDescriptor(\Visit.visitedOn, order: .reverse)]
        )
    }

    private var profile: Profile? { auth.state.profile }

    private var visitedVisits: [Visit] { visits.filter { $0.kind == .visited } }
    private var wantToTryVisits: [Visit] { visits.filter { $0.kind == .wantToTry } }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 28) {
                    identitySection
                        .padding(.horizontal, Self.contentMargin)
                    activitySection
                    testUsersCard
                        .padding(.horizontal, Self.contentMargin)
                    signInFooter
                        .padding(.horizontal, Self.contentMargin)
                }
                .padding(.vertical, 16)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Haptics.tap()
                        showAddFriends = true
                    } label: {
                        Label("Add friends", systemImage: "person.badge.plus")
                            .badgeOverlay(graph.incoming.count)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Haptics.tap()
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .navigationDestination(isPresented: $showSettings) {
                SettingsView()
            }
            .sheet(isPresented: $showAddFriends) {
                AddFriendsView()
            }
            .task {
                social = socialStats.cachedOwnStats()
                social = await socialStats.ownStats()
            }
            .onChange(of: demo.epoch) { _, _ in
                Task { await refreshSocialStats() }
            }
        }
    }

    // MARK: - Identity

    private var identitySection: some View {
        VStack(spacing: 10) {
            avatar
                .frame(width: 108, height: 108)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color(uiColor: .systemBackground), lineWidth: 3))
                .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 4)
                .accessibilityHidden(true)

            VStack(spacing: 3) {
                Text(profile?.bestName ?? "—")
                    .font(.title3.weight(.semibold))
                Text(profile?.handle ?? "")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            ProfileHeaderStats(
                friendCount: social?.friendCount ?? 0,
                beenCount: visitedVisits.count,
                wantToTryCount: wantToTryVisits.count,
                onFriendsTap: { router.activeTab = .friends },
                onBeenTap: { openList(kind: .visited) },
                onWantToTryTap: { openList(kind: .wantToTry) }
            )
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    /// Uploaded avatar when there is one, app logo as the fallback (also used
    /// while the remote image loads, so the header never jumps).
    @ViewBuilder
    private var avatar: some View {
        if let urlString = profile?.avatarURL, let url = URL(string: urlString) {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Image("Logo").resizable().scaledToFill()
            }
        } else {
            Image("Logo").resizable().scaledToFill()
        }
    }

    private func openList(kind: VisitKind) {
        filter.reset()
        filter.kinds = [kind]
        router.homeMode = .list
        router.activeTab = .home
    }

    // MARK: - Activity grid

    /// Every visited place as a photo, three to a row. Tapping one opens its
    /// write-up — the same destination the map and list use.
    @ViewBuilder
    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Activity")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if !visitedVisits.isEmpty {
                    Text(pluralized(visitedVisits.count, "place"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, Self.contentMargin)

            if visitedVisits.isEmpty {
                activityEmptyState
                    .padding(.horizontal, Self.contentMargin)
            } else {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 3),
                        GridItem(.flexible(), spacing: 3),
                        GridItem(.flexible(), spacing: 3)
                    ],
                    spacing: 3
                ) {
                    ForEach(visitedVisits) { visit in
                        Button {
                            Haptics.tap()
                            openedVisit = visit
                        } label: {
                            activityCell(for: visit)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 1)
            }
        }
    }

    private func activityCell(for visit: Visit) -> some View {
        let photo = visit.photos.sorted(by: { $0.order < $1.order }).first
        return Group {
            if let photo {
                PhotoView(source: PhotoView.Source(photo: photo, wantsThumbnail: true), contentMode: .fill)
            } else {
                ZStack {
                    Color(uiColor: .secondarySystemBackground)
                    Image(systemName: "photo")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .clipped()
    }

    private var activityEmptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)
            Text("Visits you log will show up here")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    // MARK: - Test users

    /// Overlay of sample people so friends, explore, and the map can be
    /// walked without a second real account. Does not write to Supabase and
    /// does not touch the signed-in user's own visits.
    private var testUsersCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "flask.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.orange)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.orange.opacity(0.15)))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Test users")
                        .font(.subheadline.weight(.semibold))
                    Text(demo.isEnabled
                         ? "Sample people are filling friends, explore, and the map."
                         : "Simulate friends, requests, and explore activity.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Toggle("Test users", isOn: Binding(
                    get: { demo.isEnabled },
                    set: { enabled in
                        Haptics.tap()
                        applyDemoMode(enabled)
                    }
                ))
                .labelsHidden()
                .tint(.orange)
            }

            if demo.isEnabled {
                Button {
                    Haptics.tap()
                    demo.reset()
                    propagateDemoChange()
                } label: {
                    Label("Reset sample data", systemImage: "arrow.counterclockwise")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.orange)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.orange.opacity(demo.isEnabled ? 0.45 : 0), lineWidth: 1)
        }
    }

    private func applyDemoMode(_ enabled: Bool) {
        demo.setEnabled(enabled)
        if enabled {
            audience.select(.allFriends)
        }
        propagateDemoChange()
    }

    private func propagateDemoChange() {
        graph.refresh()
        feed.refresh()
        socialStats.invalidateAll()
        friendVisits.clearResults()
        social = nil
        Task { await refreshSocialStats() }
    }

    private func refreshSocialStats() async {
        social = await socialStats.ownStats()
    }

    // MARK: - Sync footer

    /// Sync status, in the one place a user goes looking for "is my stuff safe?".
    private var signInFooter: some View {
        VStack(spacing: 8) {
            if sync.failedCount > 0 {
                Label(
                    "\(entryCountLabel(sync.failedCount)) didn't upload",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.orange)

                Button("Try again") { sync.retryFailedNow() }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.glass)

            } else if sync.pendingCount > 0 {
                Label(
                    sync.isSyncing
                        ? "Uploading \(entryCountLabel(sync.pendingCount))…"
                        : "\(entryCountLabel(sync.pendingCount)) waiting to upload",
                    systemImage: sync.isSyncing ? "arrow.triangle.2.circlepath" : "clock"
                )
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            } else {
                Label("All synced", systemImage: "checkmark.icloud.fill")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            if let lastSynced = sync.lastSyncedAt {
                Text("Last synced \(lastSynced.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                Text("Your entries sync automatically when you're online.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

}
