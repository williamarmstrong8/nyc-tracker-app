import SwiftUI

/// The explore feed: what friends have been doing, newest first.
///
/// Replaces the curated mock list that stood here. Chronological with no
/// ranking — see `FeedStore` for why — and paginated by keyset cursor so that
/// friends creating visits mid-scroll can't make rows repeat or disappear.
struct DiscoverView: View {
    @Environment(SocialGraph.self) private var graph
    @Environment(FeedStore.self) private var feed
    @Environment(AppRouter.self) private var router

    @State private var openedPlace: PlaceSummary?
    @State private var showUserSearch = false

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
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Explore")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Haptics.tap()
                        showUserSearch = true
                    } label: {
                        Label("Find people", systemImage: "person.badge.plus")
                    }
                }
            }
            .navigationDestination(for: PersonSummary.self) { person in
                FriendProfileView(person: person)
            }
            .sheet(item: $openedPlace) { place in
                RecommendedPlaceSheet(place: place)
            }
            .sheet(isPresented: $showUserSearch) {
                UserSearchView()
            }
        }
        .task { feed.refresh() }
    }

    // MARK: - List

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                ForEach(feed.items) { item in
                    FeedCard(
                        item: item,
                        onOpenPlace: { openedPlace = placeSummary(for: item) }
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

                // Clear the floating bottom nav.
                Color.clear.frame(height: 90)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .refreshable { await feed.reload() }
    }

    /// The feed's flat row carries the venue columns; this is the same place the
    /// map and inbox would show, assembled from them.
    private func placeSummary(for item: FeedItem) -> PlaceSummary {
        PlaceSummary(
            id: item.visit.placeID,
            name: item.visit.placeName,
            categoryRaw: item.visit.placeCategory,
            neighborhood: item.visit.neighborhood,
            streetAddress: item.visit.streetAddress,
            latitude: item.visit.latitude,
            longitude: item.visit.longitude
        )
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
                showUserSearch = true
            } label: {
                Label("Find people", systemImage: "person.badge.plus")
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

/// One friend visit in the feed.
///
/// Hero photo rather than the full carousel `FriendVisitCard` uses: a feed is
/// scanned, and a horizontal photo strip inside a vertical scroll is a gesture
/// conflict on every single row.
private struct FeedCard: View {
    let item: FeedItem
    var onOpenPlace: () -> Void

    private var visit: FriendVisit { item.visit }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            authorRow
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)

            if let hero = visit.photos.first {
                PhotoView(source: .remote(path: hero.storagePath), contentMode: .fill)
                    .frame(height: 200)
                    .frame(maxWidth: .infinity)
                    .clipped()
            }

            VStack(alignment: .leading, spacing: 8) {
                placeRow

                if let summary = visit.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(4)
                }

                if !visit.tags.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(visit.tags.prefix(6), id: \.self) { tag in
                            Text(tag)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Color(uiColor: .tertiarySystemFill)))
                        }
                    }
                }

                if item.friendPlaceCount > 1 {
                    // Only worth saying when it's more than the author. "1 friend
                    // has been here" on a card written by that friend is noise.
                    Label(
                        "\(pluralized(item.friendPlaceCount, "friend")) \(item.friendPlaceCount == 1 ? "has" : "have") been here",
                        systemImage: "person.2.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var authorRow: some View {
        HStack(spacing: 10) {
            NavigationLink(value: visit.person) {
                HStack(spacing: 10) {
                    PersonAvatar(person: visit.person, size: 36, showsPaletteRing: true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(visit.person.bestName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(visit.visitedAt.formatted(.relative(presentation: .named)))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let rating = visit.rating {
                Image(systemName: rating.symbol)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(rating.label)
            }
        }
    }

    private var placeRow: some View {
        Button(action: onOpenPlace) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(visit.placeName)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let neighborhood = visit.neighborhood, !neighborhood.isEmpty {
                        Text(neighborhood)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens \(visit.placeName)")
    }
}
