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
    @Environment(AppRouter.self) private var router
    @Environment(SocialGraph.self) private var graph

    @State private var showSettings = false
    @State private var cover: ProfileCover?

    /// One full-screen cover slot so friends and add-friends never compete.
    private enum ProfileCover: Identifiable {
        case friends
        case addFriends

        var id: Self { self }
    }

    @State private var tab: ProfileTab = .activity
    /// Entries friends tagged the user in. Server-backed rather than mirrored,
    /// for the same reason the wishlist is: these rows are authored by other
    /// people while this app is closed, so there is nothing local to sync.
    @State private var taggedVisits: [FriendVisit] = []
    @State private var isLoadingTagged = false
    @State private var hasLoadedTagged = false
    @State private var openedTaggedVisit: FriendVisit?

    @State private var isProfileAvatarExpanded = false
    @State private var isProfileAvatarOverlayOpaque = false
    @State private var profileAvatarFrame: CGRect = .zero

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
            sort: [
                SortDescriptor(\Visit.visitedOn, order: .reverse),
                // Upload order breaks a tie. A user backfilling several
                // places to the same day would otherwise get an order
                // SwiftData is free to change between launches.
                SortDescriptor(\Visit.createdAt, order: .reverse)
            ]
        )
    }

    private var profile: Profile? { auth.state.profile }

    private var visitedVisits: [Visit] { visits.filter { $0.kind == .visited } }
    private var wantToTryVisits: [Visit] { visits.filter { $0.kind == .wantToTry } }

    var body: some View {
        NavigationStack {
            ZStack {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 28) {
                        identitySection
                            .padding(.horizontal, Self.contentMargin)
                        activitySection
                        signInFooter
                            .padding(.horizontal, Self.contentMargin)
                    }
                    .padding(.vertical, 16)
                }
                .contentMargins(.bottom, BottomNavBar.scrollContentClearance + 16, for: .scrollContent)
                .background(Color(uiColor: .systemGroupedBackground))

                ProfileAvatarExpandLayer(
                    isExpanded: $isProfileAvatarExpanded,
                    isOverlayOpaque: $isProfileAvatarOverlayOpaque,
                    sourceFrame: profileAvatarFrame,
                    urlString: profile?.avatarURL
                ) {
                    ownAvatarFallback
                }
            }
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Haptics.tap()
                        cover = .addFriends
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
            .onChange(of: showSettings) { _, isShowing in
                router.hidesBottomBar = isShowing
            }
            .fullScreenCover(item: $cover) { destination in
                switch destination {
                case .friends:
                    FriendsNavigationStack(userID: userID, showsDismissButton: true)
                case .addFriends:
                    AddFriendsView()
                }
            }
            .sheet(item: $openedTaggedVisit) { visit in
                NavigationStack {
                    FriendVisitWriteUpView(
                        visit: visit,
                        onDismiss: { openedTaggedVisit = nil },
                        onShowOnMap: {
                            openedTaggedVisit = nil
                            router.showMap()
                        },
                        showsAuthor: false
                    )
                    .flatModalToolbarBackground()
                }
                .flatModalBackground()
            }
            .task(id: userID) {
                await loadTaggedVisits()
            }
            // A friend can tag the user at any time, and a friendship ending
            // takes tags with it. Both land here on the next sync tick rather
            // than only on a cold launch.
            .onChange(of: sync.lastSyncedAt) { _, _ in
                Task { await loadTaggedVisits() }
            }
        }
    }

    // MARK: - Identity

    private var identitySection: some View {
        VStack(spacing: 10) {
            avatar
                .frame(width: 108, height: 108)
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 4)
                .profileAvatarExpandSource(
                    isExpanded: $isProfileAvatarExpanded,
                    isOverlayOpaque: $isProfileAvatarOverlayOpaque,
                    sourceFrame: $profileAvatarFrame
                )

            VStack(spacing: 3) {
                Text(profile?.bestName ?? "—")
                    .font(.title3.weight(.semibold))
                Text(profile?.handle ?? "")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            ProfileHeaderStats(
                friendCount: graph.friends.count,
                beenCount: visitedVisits.count,
                wantToTryCount: wantToTryVisits.count,
                onFriendsTap: { cover = .friends },
                onBeenTap: { openList(kind: .visited) },
                onWantToTryTap: { openList(kind: .wantToTry) }
            )
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    /// Uploaded avatar when there is one, the user's own initials as the
    /// fallback (also used while the remote image loads, so the header never
    /// jumps — and never dips into the app's logo to stand in for a face).
    ///
    /// After the first load the header draws the real picture immediately on
    /// every subsequent launch: the avatar URL carries the upload's `?v=` stamp,
    /// so `AvatarCache` can treat it as immutable and keep it until the user
    /// changes their picture.
    private var avatar: some View {
        AvatarImage(urlString: profile?.avatarURL) {
            ownAvatarFallback
        }
    }

    /// Initials once the profile has loaded; a neutral silhouette for the
    /// sliver of time before it has, since there's no name yet to initial.
    @ViewBuilder
    private var ownAvatarFallback: some View {
        if let profile {
            PersonInitialsView(person: profile.personSummary)
        } else {
            PersonUnknownAvatar()
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
            ProfileTabPicker(selection: $tab)
                .padding(.horizontal, Self.contentMargin)

            switch tab {
            case .activity: ownGrid
            case .tagged:   taggedGrid
            }
        }
    }

    private static let gridColumns = [
        GridItem(.flexible(), spacing: 3),
        GridItem(.flexible(), spacing: 3),
        GridItem(.flexible(), spacing: 3)
    ]

    @ViewBuilder
    private var ownGrid: some View {
        if visitedVisits.isEmpty {
            activityEmptyState
                .padding(.horizontal, Self.contentMargin)
        } else {
            LazyVGrid(columns: Self.gridColumns, spacing: 3) {
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
            .task(id: visitedVisits.count) {
                prefetchActivityPhotos()
            }
        }
    }

    /// Entries friends tagged the user in. Opens the friend write-up sheet, not
    /// the owned one — these are somebody else's entries, with no edit or delete
    /// path from here.
    @ViewBuilder
    private var taggedGrid: some View {
        if isLoadingTagged && taggedVisits.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
        } else if taggedVisits.isEmpty {
            taggedEmptyState
                .padding(.horizontal, Self.contentMargin)
        } else {
            LazyVGrid(columns: Self.gridColumns, spacing: 3) {
                ForEach(taggedVisits) { visit in
                    Button {
                        Haptics.tap()
                        openedTaggedVisit = visit
                    } label: {
                        taggedCell(for: visit)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 1)
        }
    }

    private func taggedCell(for visit: FriendVisit) -> some View {
        let photo = visit.photos.sorted(by: { $0.sortOrder < $1.sortOrder }).first
        return Color.clear
            .aspectRatio(3 / 4, contentMode: .fit)
            .overlay {
                if let photo {
                    PhotoView(source: .friendPhoto(path: photo.smallestPath), contentMode: .fill)
                } else {
                    ZStack {
                        Color(uiColor: .secondarySystemBackground)
                        Image(systemName: "photo")
                            .font(.title3)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            // Whose entry this is matters more here than on the user's own grid,
            // where the answer is always "yours".
            .overlay(alignment: .bottomLeading) {
                PersonAvatar(person: visit.person, size: 20)
                    .overlay { Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1) }
                    .padding(5)
            }
    }

    private var taggedEmptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "person.2")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)
            Text("Nothing yet")
                .font(.headline)
            Text("When a friend tags you in a place they logged, it shows up here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private func loadTaggedVisits() async {
        // Only the first load shows a spinner. A refresh triggered by a sync
        // tick should not blank a grid the user is looking at.
        isLoadingTagged = !hasLoadedTagged
        defer {
            isLoadingTagged = false
            hasLoadedTagged = true
        }

        // A failure leaves whatever was already loaded on screen. This tab is
        // not the reason the user opened their profile, and an error banner over
        // a photo grid is worse than a slightly stale one.
        taggedVisits = (try? await VisitTagService.taggedVisits(of: userID)) ?? taggedVisits
    }

    /// Warm the photo cache for the top of the activity grid.
    ///
    /// Only matters after a reinstall, which is exactly when it matters most: the
    /// visit rows sync down in one pass and the images do not, so the grid would
    /// otherwise start downloading a thumbnail at the moment each cell scrolls
    /// into view and fill in one square at a time under the user's thumb.
    ///
    /// Deriving the source rather than reading `remoteThumbPath` off the row is
    /// deliberate — it keeps the local-file-first preference in one place. A
    /// photo still on this device resolves to `.relativePath` and is skipped,
    /// because there is nothing to fetch.
    private func prefetchActivityPhotos() {
        let paths = visitedVisits.compactMap { visit -> String? in
            guard let photo = visit.photos.min(by: { $0.order < $1.order }) else { return nil }
            guard case .remote(let path) = PhotoView.Source(photo: photo, wantsThumbnail: true) else {
                return nil
            }
            return path
        }
        PhotoCache.shared.prefetch(paths)
    }

    private func activityCell(for visit: Visit) -> some View {
        let photo = visit.photos.sorted(by: { $0.order < $1.order }).first
        return Color.clear
            .aspectRatio(3 / 4, contentMode: .fit)
            .overlay {
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
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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
