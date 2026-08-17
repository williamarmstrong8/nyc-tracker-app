import SwiftUI
import SwiftData

/// The explore feed: what friends have been doing, newest first.
///
/// Replaces the curated mock list that stood here. Chronological with no
/// ranking — see `FeedStore` for why — and paginated by keyset cursor so that
/// friends creating visits mid-scroll can't make rows repeat or disappear.
struct DiscoverView: View {
    @Environment(SocialGraph.self) private var graph
    @Environment(FeedStore.self) private var feed
    @Environment(AppRouter.self) private var router
    @Environment(SocialDemoMode.self) private var demo

    @State private var openedItem: FeedItem?
    @State private var showAddFriends = false
    /// How far the feed has scrolled past the top. Drives the title offset 1:1.
    @State private var scrollOffset: CGFloat = 0

    /// Distance over which the title fully leaves the bar with the scroll.
    private static let titleScrollDistance: CGFloat = 44

    var body: some View {
        NavigationStack {
            Group {
                if !feed.hasLoaded && feed.isRefreshing {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if graph.hasLoaded && graph.friends.isEmpty {
                    noFriendsState
                } else if feed.items.isEmpty && feed.hasLoaded {
                    quietFeedState
                } else {
                    list
                }
            }
            .background(Color(uiColor: .systemBackground))
            .navigationTitle("Explore")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    exploreTitle
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Haptics.tap()
                        showAddFriends = true
                    } label: {
                        Label("Add friends", systemImage: "person.badge.plus")
                            .badgeOverlay(graph.incoming.count)
                    }
                }
            }
            .navigationDestination(for: PersonSummary.self) { person in
                FriendProfileView(person: person)
            }
            .sheet(isPresented: $showAddFriends) {
                AddFriendsView()
            }
            .sheet(item: $openedItem) { item in
                NavigationStack {
                    FriendVisitWriteUpView(
                        visit: item.visit,
                        onDismiss: { openedItem = nil },
                        onShowOnMap: {
                            openedItem = nil
                            router.showMap()
                        }
                    )
                    .toolbarBackground(.black, for: .navigationBar)
                    .toolbarBackgroundVisibility(.visible, for: .navigationBar)
                }
                .preferredColorScheme(.dark)
                .presentationBackground(.black)
            }
        }
        .task { feed.refresh() }
    }

    /// Overlay title in the sticky bar. Buttons stay put; the title tracks
    /// scroll offset directly — no animation, just moves up with the feed.
    private var exploreTitle: some View {
        let travel = min(max(scrollOffset, 0), Self.titleScrollDistance)
        let progress = travel / Self.titleScrollDistance

        return VStack(spacing: 1) {
            Text("Explore").font(.headline)
            if demo.isEnabled {
                Text("Sample activity").font(.caption2).foregroundStyle(.orange)
            }
        }
        .opacity(1 - progress)
        .offset(y: -travel)
        .frame(minHeight: 34)
        .clipped()
        .accessibilityElement(children: .combine)
        .accessibilityHidden(progress >= 1)
    }

    // MARK: - List

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 28) {
                ForEach(feed.items) { item in
                    FeedCard(
                        item: item,
                        onOpenPlace: { openedItem = item }
                    )
                    // Prefetch three rows out, so the next page is usually
                    // already there by the time the user reaches it.
                    .onAppear { feed.loadMoreIfNeeded(currentItem: item) }
                }

                if feed.isLoadingMore {
                    ProgressView()
                        .padding(.vertical, 20)
                } else if !feed.canLoadMore && feed.items.count > 5 {
                    Text("You're all caught up.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 24)
                }
            }
            .padding(.horizontal, 1)
            .padding(.vertical, 12)
        }
        .refreshable { await feed.reload() }
        .scrollEdgeEffectHidden(true, for: .top)
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top
        } action: { _, newOffset in
            scrollOffset = newOffset
        }
    }

    // MARK: - Empty states

    /// No friends at all — the feed has no source, so it points at the fix
    /// rather than sitting empty.
    private var noFriendsState: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text("Nothing to explore yet")
                .font(.headline)
            Text("Add friends and their places will show up here as they log them.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                Haptics.tap()
                showAddFriends = true
            } label: {
                Label("Add friends", systemImage: "person.badge.plus")
                    .frame(minWidth: 200, minHeight: 44)
            }
            .buttonStyle(.glassProminent)
            .padding(.top, 6)

            Button {
                Haptics.tap()
                router.activeTab = .friends
            } label: {
                Text("See your friends")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.glass)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Friends exist but none of them have logged anything. A different problem
    /// from having no friends, so it gets a different answer.
    private var quietFeedState: some View {
        VStack(spacing: 10) {
            Image(systemName: "clock")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            Text("No activity yet")
                .font(.headline)
            Text("When your friends log a place, it'll appear here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Feed card

/// One friend visit in the explore feed.
///
/// BeReal-shaped: avatar + username + time, then a nearly full-width 3:4
/// photo carousel, then the place and write-up as type underneath — not
/// inside a card. `PhotoCarousel` pages horizontally without stealing the
/// outer vertical scroll.
private struct FeedCard: View {
    let item: FeedItem
    var onOpenPlace: () -> Void

    private var visit: FriendVisit { item.visit }

    private var photoSources: [PhotoView.Source] {
        visit.photos
            .sorted { $0.sortOrder < $1.sortOrder }
            .map { PhotoView.Source.friendPhoto(path: $0.storagePath) }
    }

    private var username: String {
        if let name = visit.person.username, !name.isEmpty { return name }
        return visit.person.bestName
    }

    private var neighborhoodText: String? {
        let value = visit.neighborhood?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private var timeText: String {
        visit.visitedAt.formatted(.relative(presentation: .numeric, unitsStyle: .narrow))
    }

    private var metaLine: String {
        if let neighborhoodText {
            return "\(neighborhoodText) • \(timeText)"
        }
        return timeText
    }

    private var summaryText: String? {
        if let summary = visit.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
           !summary.isEmpty {
            return summary
        }
        if let transcript = visit.transcript?.trimmingCharacters(in: .whitespacesAndNewlines),
           !transcript.isEmpty {
            return transcript
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            authorRow
                .padding(.horizontal, 10)

            photoCarousel
                .onTapGesture(perform: onOpenPlace)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("\(visit.placeName) photos")
                .accessibilityHint("Opens \(visit.person.shortName)'s visit")

            caption
                .padding(.horizontal, 10)
                .contentShape(Rectangle())
                .onTapGesture(perform: onOpenPlace)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Avatar/name on the left navigate to the friend's profile; save/share on
    /// the right act on the place. Two separate tap targets in one row rather
    /// than one `NavigationLink` wrapping everything, so tapping an action icon
    /// doesn't also push the profile.
    private var authorRow: some View {
        HStack(spacing: 10) {
            NavigationLink(value: visit.person) {
                HStack(spacing: 10) {
                    PersonAvatar(person: visit.person, size: 36)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(username)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(metaLine)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(visit.person.bestName)
            .accessibilityHint("Opens profile")

            Spacer(minLength: 0)

            ExplorePlaceActions(place: visit.placeSummary, photo: photoSources.first)
        }
    }

    private var photoCarousel: some View {
        Color.clear
            .aspectRatio(3 / 4, contentMode: .fit)
            .overlay {
                if photoSources.isEmpty {
                    emptyPhoto
                } else {
                    PhotoCarousel(sources: photoSources)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var emptyPhoto: some View {
        ZStack {
            Color(uiColor: .secondarySystemFill)
            Image(systemName: visit.visitKind == .wantToTry ? "bookmark" : "photo")
                .font(.system(size: 40, weight: .ultraLight))
                .foregroundStyle(.tertiary)
        }
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(visit.placeName)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            if let summaryText {
                Text(summaryText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
            }

            if item.friendPlaceCount > 1 {
                Text("\(pluralized(item.friendPlaceCount, "friend")) \(item.friendPlaceCount == 1 ? "has" : "have") been here")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Save / share icons

/// Icon-only save and send, right-aligned in the author row.
///
/// The feed card's content layer stays clean (no glass, no buttons with
/// backgrounds) — these are plain glyphs, like a like/save row on any photo
/// feed, not the full labeled buttons `PlaceActionsRow` uses in a detail
/// sheet's functional layer.
private struct ExplorePlaceActions: View {
    let place: PlaceSummary
    var photo: PhotoView.Source? = nil

    @Environment(WishlistStore.self) private var wishlist
    @Environment(SocialStatsCache.self) private var stats
    @Environment(\.modelContext) private var modelContext
    @Environment(AuthManager.self) private var auth
    @Environment(SyncEngine.self) private var sync

    @State private var isSaving = false
    @State private var showSendSheet = false
    @State private var showSavedConfirmation = false
    @State private var confirmationTask: Task<Void, Never>?
    /// What the tap asked for, held only until the store catches up. The save
    /// RPC is a round trip; without this the bookmark stays hollow for as long
    /// as the network takes and the tap reads as if it did nothing.
    @State private var pendingSaved: Bool?

    private var savedEntry: WishlistEntry? { wishlist.entry(forPlace: place.id) }
    private var isSaved: Bool { pendingSaved ?? (savedEntry != nil) }

    var body: some View {
        // No spacing between the two: the 36pt tap frames already hold them
        // apart, and the pair reads as one action cluster rather than two
        // unrelated glyphs.
        HStack(spacing: 0) {
            shareButton
            saveButton
        }
        .overlay(alignment: .topTrailing) {
            if showSavedConfirmation {
                savedConfirmation
                    .offset(y: -36)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .sheet(isPresented: $showSendSheet) {
            SendPlaceSheet(place: place, photo: photo)
        }
    }

    private var saveButton: some View {
        Button {
            Haptics.tap()
            Task { await toggleSaved() }
        } label: {
            Image(systemName: isSaved ? "bookmark.fill" : "bookmark")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(isSaved ? Color.blue : Color.primary)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 36, height: 36)
        }
        .buttonStyle(.plain)
        .disabled(isSaving)
        .accessibilityLabel(isSaved ? "Remove from want to try" : "Save to want to try")
    }

    private var shareButton: some View {
        Button {
            Haptics.tap()
            showSendSheet = true
        } label: {
            Image(systemName: "paperplane")
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(Color.primary)
                .frame(width: 36, height: 36)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Send to a friend")
    }

    private var savedConfirmation: some View {
        Label("Added to Want to Try", systemImage: "checkmark")
            .font(.caption.weight(.semibold))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(.black.opacity(0.82)))
            .fixedSize()
    }

    private func toggleSaved() async {
        isSaving = true
        withAnimation(.snappy) { pendingSaved = !isSaved }
        defer {
            isSaving = false
            pendingSaved = nil
        }

        if let savedEntry {
            let removed = await wishlist.remove(itemID: savedEntry.id)
            if removed { mirror?.removeMirror(placeID: place.id) }
        } else {
            let success = await wishlist.add(placeID: place.id)
            if success {
                mirror?.mirror(place)
                announceSaved()
            }
        }
        // The local mirror is a new local write like any other — the map and the
        // Want to try list read it immediately, but the cloud copy still has to
        // be pushed.
        sync.requestSync(reason: .newLocalWrite)
        // The user's own action — must be reflected immediately rather than
        // waiting out the stats TTL.
        stats.invalidate(placeID: place.id)
    }

    /// The Want to try mirror, once there is a signed-in user to attribute rows
    /// to. Nil before sign-in, where there is no wishlist to save from anyway.
    private var mirror: WantToTryMirror? {
        guard let userID = auth.state.profile?.id else { return nil }
        return WantToTryMirror(context: modelContext, userID: userID)
    }

    /// Brief confirmation instead of a modal or persistent banner — the same
    /// weight as the tap that triggered it. Cancels/replaces any confirmation
    /// still fading from a previous tap so rapid toggling can't stack timers.
    private func announceSaved() {
        confirmationTask?.cancel()
        withAnimation(.snappy) { showSavedConfirmation = true }
        confirmationTask = Task {
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            withAnimation(.snappy) { showSavedConfirmation = false }
        }
    }
}
